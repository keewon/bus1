-module(web_interface_handler).
-behaviour(cowboy_http_handler).
-include("bus_archive.hrl").

-export([init/3]).
-export([handle/2]).
-export([terminate/3]).

-record(state, {
         }).

init(_, Req, _Opts) ->
    {ok, Req, #state{}}.

handle(Req1, State=#state{}) ->
    lager:info("handle ~p", [Req1]),
    {Action, Req2} = cowboy_req:qs_val(<<"action">>, Req1),
    {BusId, Req3} = cowboy_req:qs_val(<<"id">>, Req2),

    {StatusCode, Body} = case handle_action(Action, [BusId]) of
        {ok, _Pid} ->
            {200, <<"OK">>};
        {error, {already_started, _}} ->
            {409, <<"Conflict">>};
        _ ->
            {500, <<"Internal Server Error">>}
    end,

    ReqBeforeReply = Req3,
    {ok, ReqFinal} = cowboy_req:reply(
                   StatusCode,
                   [{<<"content-type">>, <<"text/plain">>}],
                   Body,
                   ReqBeforeReply),
    {ok, ReqFinal, State}.

terminate(_Reason, _Req, _State) ->
    ok.

handle_action(<<"add">>, [BusId]) ->
    supervisor:start_child(worker_sup, [BusId]).

