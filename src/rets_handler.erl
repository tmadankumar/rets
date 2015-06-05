%% -*- mode: erlang; erlang-indent-level: 2 -*-
%%% Created : 20 Jan 2014 by mats cronqvist <masse@klarna.com>

%% @doc
%% @end

-module(rets_handler).
-author('mats cronqvist').

%% the API
-export([state/0]).

%% for application supervisor
-export([start_link/1]).

%% gen_server callbacks
-behaviour(gen_server).
-export([init/1,terminate/2,code_change/3,
         handle_call/3,handle_cast/2,handle_info/2]).

%% the API
state() ->
  gen_server:call(?MODULE,state).

%% for application supervisor
start_link(Args) ->
  gen_server:start_link({local,?MODULE},?MODULE,Args,[]).

%% gen_server callbacks
init(Args) ->
  process_flag(trap_exit, true),
  do_init(Args).

terminate(shutdown,State) ->
  do_terminate(State).

code_change(_OldVsn,State,_Extra) ->
  {ok,State}.

handle_call(state,_From,State) ->
  {reply,expand_recs(State),State};
handle_call(stop,_From,State) ->
  {stop,normal,stopping,State};
handle_call(What,_From,State) ->
  do_handle_call(What,State).

handle_cast(What,State) ->
  erlang:display({cast,What}),
  {noreply,State}.

handle_info(What,State) ->
  erlang:display({info,What}),
  {noreply,State}.

%% utility to print state
expand_recs(List) when is_list(List) ->
  [expand_recs(I) || I <- List];
expand_recs(Tup) when is_tuple(Tup) ->
  case tuple_size(Tup) of
    L when L < 1 -> Tup;
    L ->
      try Fields = rec_info(element(1,Tup)),
          L = length(Fields)+1,
          lists:zip(Fields,expand_recs(tl(tuple_to_list(Tup))))
      catch _:_ ->
          list_to_tuple(expand_recs(tuple_to_list(Tup)))
      end
  end;
expand_recs(Term) ->
  Term.

%% boilerplate ends here

%% declare the state
-record(state,{
          %% Settable parameters
          %% Set from erl start command (erl -rets backend leveldb)
          backend   = leveldb, %% leveldb|ets
          env       = [],      %% result of application:get_all_env(rets)
          table_dir = "/tmp/rets/db",
          keep_db   = false,

          %% Non-settable paramaters
          cb_mod,  %% rets BE callback module
          cb_state %% BE callback state
         }).

rec_info(state) -> record_info(fields,state).

do_init(Args) ->
  S  = #state{},
  BE = getv(backend,Args,S#state.backend),
  KD = getv(keep_db,Args,S#state.keep_db),
  TD = getv(table_dir,Args,S#state.table_dir),
  CB = list_to_atom("rets_"++atom_to_list(BE)),
  keep_or_delete_db(KD,TD),
  {ok,S#state{
        backend   = BE,
        table_dir = TD,
        keep_db   = KD,
        env       = Args,
        cb_mod    = CB,
        cb_state  = CB:init([{keep_db,KD},{table_dir,TD}])}}.

do_terminate(S) ->
  (S#state.cb_mod):terminate(S#state.cb_state,S#state.keep_db),
  keep_or_delete_db(S#state.keep_db,S#state.table_dir).

do_handle_call({F,Args},State) ->
  try
    {Reply,CBS} = (State#state.cb_mod):F(State#state.cb_state,Args),
    {reply,{ok,Reply},State#state{cb_state=CBS}}
  catch
    throw:{Status,Term} -> {reply,{Status,Term},State}
  end.

keep_or_delete_db(true,_TableDir) -> ok;
keep_or_delete_db(false,TableDir) -> delete_recursively(TableDir).

-include_lib("kernel/include/file.hrl").
-define(filetype(Type), #file_info{type=Type}).

delete_recursively(File) ->
  case file:read_file_info(File) of
    {error,enoent} ->
      ok;
    {ok,?filetype(directory)} ->
      {ok,Fs} = file:list_dir(File),
      Del = fun(F) -> delete_recursively(filename:join(File,F)) end,
      lists:foreach(Del,Fs),
      delete_file(del_dir,File);
    {ok,?filetype(regular)} ->
      delete_file(delete,File)
  end.

delete_file(Op,File) ->
  case file:Op(File) of
    ok -> ok;
    {error,Err} -> throw({500,{file_delete_error,{Err,File}}})
  end.

getv(K,PL,Def) ->
  proplists:get_value(K,PL,Def).
