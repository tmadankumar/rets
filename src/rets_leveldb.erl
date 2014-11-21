%% -*- mode: erlang; erlang-indent-level: 2 -*-
%%% Created : 21 Oct 2014 by Mats Cronqvist <masse@klarna.com>

%% @doc
%% @end

-module('rets_leveldb').
-author('Mats Cronqvist').
-export([init/1,
         terminate/1,
         create/2,
         delete/2,
         sizes/2,
         keys/2,
         insert/2,
         bump/2,
         reset/2,
         next/2,
         prev/2,
         multi/2,
         single/2]).

-record(state,
        {tables=[],
         handle,
         dir}).

init(Env) ->
  ets:new(leveldb_tabs,[ordered_set,named_table,public]),
  Dir = proplists:get_value(table_dir,Env,"/tmp/rets/leveldb"),
  filelib:ensure_dir(Dir),
  #state{handle = lvl_open(Dir),
         dir = Dir}.

terminate(S) ->
  lvl_close(S),
  delete_recursively(S#state.dir).

delete_recursively(File) ->
  case filelib:is_dir(File) of
    true ->
      {ok,Fs} = file:list_dir(File),
      Del = fun(F) -> delete_recursively(filename:join(File,F)) end,
      lists:foreach(Del,Fs),
      delete_file(del_dir,File);
    false->
      delete_file(delete,File)
  end.

delete_file(Op,File) ->
  case file:Op(File) of
    ok -> ok;
    {error,Err} -> throw({500,{file_delete_error,{Err,File}}})
  end.

%% ::(#state{},list(term(Args)) -> {jiffyable(Reply),#state{}}
create(S ,[Tab])       -> {create(tab_name(Tab)),S}.
delete(S ,[Tab])       -> {delete(tab_name(Tab)),S};
delete(S ,[Tab,Key])   -> {deleter(S,tab(Tab),Key),S}.
sizes(S  ,[])          -> {siz(),S}.
keys(S   ,[Tab])       -> {key_getter(S,tab(Tab)),S}.
insert(S ,[Tab,KVs])   -> {ins(S,tab(Tab),KVs),S};
insert(S ,[Tab,K,V])   -> {ins(S,tab(Tab),[{K,V}]),S}.
bump(S   ,[Tab,Key,I]) -> {update_counter(S,tab(Tab),Key,I),S}.
reset(S  ,[Tab,Key,I]) -> {reset_counter(S,tab(Tab),Key,I),S}.
next(S   ,[Tab,Key])   -> {nextprev(S,next,tab(Tab),Key),S}.
prev(S   ,[Tab,Key])   -> {nextprev(S,prev,tab(Tab),Key),S}.
multi(S  ,[Tab,Key])   -> {getter(S,multi,tab(Tab),Key),S}.
single(S ,[Tab,Key])   -> {getter(S,single,tab(Tab),Key),S}.

create(Tab) ->
  case ets:lookup(leveldb_tabs,Tab) of
    [{Tab,_Size}] -> false;
    []            -> ets:insert(leveldb_tabs,{Tab,0}),true
  end.

delete(Tab) ->
  case ets:lookup(leveldb_tabs,Tab) of
    [{Tab,_Size}] -> ets:delete(leveldb_tabs,Tab),true;
    []            -> false
  end.

siz() ->
  case ets:tab2list(leveldb_tabs) of
    [] -> [];
    TS -> {[{list_to_atom(tab_unname(T)),S} || {T,S} <- TS]}
  end.

key_getter(S,Tab) ->
  Fun = fun(TK,Acc) -> [tk_key(TK)|Acc] end,
  Iter = lvl_iter(S,keys_only),
  R = fold_loop(lvl_mv_iter(Iter,Tab),Tab,Iter,Fun,[]),
  lists:reverse(R).

fold_loop(invalid_iterator,_,_,_,Acc) ->
  Acc;
fold_loop(TK,Tab,Iter,Fun,Acc) ->
  case tk_tab(TK) of
    Tab -> fold_loop(lvl_mv_iter(Iter,prefetch),Tab,Iter,Fun,Fun(TK,Acc));
    _   -> Acc
  end.

update_counter(S,Tab,Key,Incr) ->
  case lvl_get(S,tk(Tab,Key)) of
    not_found -> ins_overwrite(S,Tab,Key,Incr);
    Val       -> ins_overwrite(S,Tab,Key,Val+Incr)
  end.

reset_counter(S,Tab,Key,Val) ->
  ins_overwrite(S,Tab,Key,Val).

ins(S,Tab,KVs) ->
  lists:foreach(fun({Key,Val}) -> ins_ifempty(S,Tab,Key,Val) end,KVs),
  true.

%%            key exists  doesn't exist
%% ifempty       N           W
%% overwrite     W           W

ins_ifempty(S,Tab,Key,Val) ->
  TK = tk(Tab,Key),
  case lvl_get(S,TK) of
    not_found ->
      ets:update_counter(leveldb_tabs,Tab,1),
      do_ins(S,TK,Val);
    Vl ->
      throw({409,{key_exists,{Tab,Key,Vl}}})
  end.

ins_overwrite(S,Tab,Key,Val) ->
  TK = tk(Tab,Key),
  case lvl_get(S,TK) of
    not_found -> ets:update_counter(leveldb_tabs,Tab,1);
    _         -> ok
  end,
  do_ins(S,TK,Val).

do_ins(S,TK,Val) ->
  lvl_put(S,TK,pack_val(Val)),
  Val.

%% get data from leveldb.
%% allow wildcards (".") in keys
getter(S,single,Tab,Ekey) ->
  case getter(S,multi,Tab,Ekey) of
    {[{_,V}]} -> V;
    _         -> throw({404,multiple_hits})
  end;
getter(S,multi,Tab,Ekey) ->
  case lvl_get(S,tk(Tab,Ekey)) of
    not_found ->
      case next(S,tk(Tab,Ekey),Ekey,[]) of
        [] -> throw({404,no_such_key});
        As -> {As}
      end;
    Val ->
      {[{list_to_binary(string:join(Ekey,"/")),Val}]}
  end.

next(S,TK,WKey,Acc) ->
  case nextprev(S,next,TK) of
    end_of_table -> lists:reverse(Acc);
    {NewTK,V} ->
      Key = tk_key(NewTK),
      case key_match(WKey,mk_ekey(Key)) of
        true -> next(S,NewTK,WKey,[{Key,unpack_val(V)}|Acc]);
        false-> Acc
      end
  end.

key_match([],[])               -> true;
key_match(["."|Wkey],[_|Ekey]) -> key_match(Wkey,Ekey);
key_match([E|Wkey],[E|Ekey])   -> key_match(Wkey,Ekey);
key_match(_,_)                 -> false.

nextprev(S,OP,Tab,Key) ->
  case nextprev(S,OP,tk(Tab,Key)) of
    end_of_table -> throw({409,end_of_table});
    {TK,V}    -> {[{tk_key(TK),unpack_val(V)}]}
  end.

nextprev(S,OP,TK) ->
  Iter = lvl_iter(S,key_vals),
  check_np(OP,lvl_mv_iter(Iter,TK),Iter,TK).

check_np(prev,invalid_iterator,Iter,TK) ->
  case lvl_mv_iter(Iter,last) of
    invalid_iterator -> throw({409,end_of_table});
    {LastTK,Val} ->
      case LastTK < TK of
        true -> check_np(prev,{LastTK,Val},Iter,TK);
        false-> check_np(next,invalid_iterator,Iter,TK)
      end
  end;
check_np(_,invalid_iterator,_,_) ->
  end_of_table;
check_np(OP,{TK,_},Iter,TK) ->
  check_np(OP,lvl_mv_iter(Iter,OP),Iter,TK);
check_np(_,{TK,V},_,_) ->
  {TK,V}.

deleter(S,Tab,Key) ->
  TK = tk(Tab,Key),
  case lvl_get(S,TK) of
    not_found ->
      null;
    Val ->
      lvl_delete(S,tk(Tab,Key)),
      ets:update_counter(leveldb_tabs,Tab,-1),
      Val
  end.

%% data packing
pack_val(Val) ->
  term_to_binary(Val).
unpack_val(Val) ->
  binary_to_term(Val).

%% table names
tab(Tab) ->
  case ets:lookup(leveldb_tabs,tab_name(Tab)) of
    [{TabName,_}] -> TabName;
    [] -> throw({404,no_such_table})
  end.

tab_name(Tab) ->
  list_to_binary([$/|Tab]).

tab_unname(Tab) ->
  tl(binary_to_list(Tab)).

%% key mangling
mk_ekey(Bin) ->
  string:tokens(binary_to_list(Bin),"/").

tk(Tab,ElList) ->
  Key = list_to_binary(string:join(ElList,"/")),
  <<Tab/binary,$/,Key/binary>>.

tk_key(TK) ->
  tl(re:replace(TK,"^/[a-zA-Z0-9-_]+/","")).

tk_tab(TK) ->
  [<<>>,Tab|_] = re:split(TK,"/"),
  <<$/,Tab/binary>>.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% leveldb API

lvl_open(Dir) ->
  case eleveldb:open(Dir,[{create_if_missing,true}]) of
    {ok,Handle} -> Handle;
    {error,Err} -> throw({500,{open_error,Err}})
  end.

lvl_close(S) ->
  case eleveldb:close(S#state.handle) of
    ok          -> ok;
    {error,Err} -> throw({500,{close_error,Err}})
  end.

lvl_iter(S,What) ->
  {ok,Iter} =
    case What of
      keys_only -> eleveldb:iterator(S#state.handle,[],keys_only);
      key_vals  -> eleveldb:iterator(S#state.handle,[])
    end,
  Iter.

lvl_mv_iter(Iter,Where) ->
  case eleveldb:iterator_move(Iter,Where) of
    {ok,Key,Val}             -> {Key,Val};
    {ok,Key}                 -> Key;
    {error,invalid_iterator} -> invalid_iterator;
    {error,Err}              -> throw({500,{iter_error,Err}})
  end.

lvl_get(S,Key) ->
  case eleveldb:get(S#state.handle,Key,[]) of
    {ok,V}      -> unpack_val(V);
    not_found   -> not_found;
    {error,Err} -> throw({500,{get_error,Err}})
  end.

lvl_put(S,Key,Val) ->
  case eleveldb:put(S#state.handle,Key,Val,[]) of
    ok          -> Val;
    {error,Err} -> throw({500,{put_error,Err}})
  end.

lvl_delete(S,Key) ->
  case eleveldb:delete(S#state.handle,Key,[]) of
    ok          -> true;
    {error,Err} -> throw({500,{delete_error,Err}})
  end.
