-module(bus_archive_app).
-behaviour(application).
-include("bus_archive.hrl").

-export([start/0, start/2]).
-export([stop/1, stop/0]).

start(_Type, _Args) ->
    bus_archive_sup:start_link().

stop(_State) ->
    ok.

start() ->
    application:ensure_all_started(bus_archive).

stop() ->
    application:stop(bus_archive).
