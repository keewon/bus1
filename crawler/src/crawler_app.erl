-module(crawler_app).
-behaviour(application).
-include("crawler.hrl").

-export([start/0, start/2]).
-export([stop/1]).

start() ->
    crawler_sup:start_link().

start(_Type, _Args) ->
    crawler_sup:start_link().

stop(_State) ->
    ok.
