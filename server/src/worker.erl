-module(worker).
-behaviour(gen_server).
-include("bus_archive.hrl").

%% API.
-export([start_link/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
          id
         }).

%% API.

%-spec start_link() -> {ok, pid()}.
start_link(BusId) ->
    LId = binary_to_list(BusId),
    AId = list_to_atom("worker_" ++ LId),
    gen_server:start_link({local, AId}, ?MODULE, [BusId], []).

%% gen_server.

init([BusId]) ->
    lager:info("start bus ~p", [BusId]),
    erlang:send_after(10000, self(), check),
    {ok, #state{id=BusId}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check, #state{id=BusId} = State) ->
    lager:info("check bus ~p", [BusId]),
    erlang:send_after(10000, self(), check),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
