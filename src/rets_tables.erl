%% -*- mode: erlang; erlang-indent-level: 2 -*-
%%% Created : 20 Jan 2014 by mats cronqvist <masse@klarna.com>

%% @doc
%% @end

-module('rets_tables').
-author('mats cronqvist').

%% the API
-export([state/0]).

%% for application supervisor
-export([start_link/0]).

%% gen_server callbacks
-behaviour(gen_server).
-export([init/1,terminate/2,code_change/3,
         handle_call/3,handle_cast/2,handle_info/2]).

%% declare the state
-record(state,{tables = []}).

%% add all records here, to kludge around the record kludge.
rec_info(state) -> record_info(fields,state);
rec_info(_)     -> [].

%% the API
state() ->
  gen_server:call(?MODULE,state).

%% for application supervisor
start_link() ->
  gen_server:start_link({local,?MODULE},?MODULE,[],[]).

%% gen_server callbacks
init(_) ->
  {ok,#state{}}.

terminate(_Reason,_State) ->
  ok.

code_change(_OldVsn,State,_Extra) ->
  {ok,State}.

handle_call(state,_From,State) ->
  {reply,expand_recs(State),State};
handle_call(stop,_From,State) ->
  {stop,normal,stopping,State};
handle_call(What,_From,State) ->
  {Reply,S} = do_handle_call(What,State),
  {reply,Reply,S}.

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

do_handle_call({create,Tab},S) ->
  assert_deleted(Tab),
  assert_created(Tab),
  {ok,S#state{tables=[Tab|S#state.tables]}};
do_handle_call({delete,Tab},S) ->
  assert_deleted(Tab),
  {ok,S#state{tables=[S#state.tables]--[Tab]}};
do_handle_call(What,State) ->
  {What,State}.

assert_created(Tab) ->
  [ets:new(Tab,[named_table,ordered_set]) || ets:info(Tab,size) =:= undefined].

assert_deleted(Tab) ->
  [ets:delete(Tab) || ets:info(Tab,size) =/= undefined].
