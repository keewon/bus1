-module(crawler_app).
-behaviour(application).
-include("crawler.hrl").

-export([start/0, start/2]).
-export([stop/1, stop/0]).

start(_Type, _Args) ->
    crawler_sup:start_link().

stop(_State) ->
    ok.

start() ->
    application:ensure_all_started(crawler).

stop() ->
    application:stop(crawler).
