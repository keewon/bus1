-module(bus_archive_sup).
-behaviour(supervisor).
-include("bus_archive.hrl").

-export([start_link/0, start_listeners/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Procs = [
        {web_interface_listener, {bus_archive_sup, start_listeners, []}, permanent, 1000, worker, [bus_archive_sup]}
    ],
    lager:info("hello!", []),
    {ok, {{one_for_one, 1, 5}, Procs}}.

start_listeners() ->
    {ok, Port} = application:get_env(bus_archive, http_port),
    {ok, ListenerCount} = application:get_env(bus_archive, http_listener_count),
    
    Dispatch = cowboy_router:compile(
        [
            {
                '_',
                [
                {"/", cowboy_static, {file, "priv/index.html"}},
                {<<"/web">>, web_interface_handler, []}
                ]
            }
        ]),
    
    RanchOptions =
        [ 
          {port, Port}
        ],
    CowboyOptions =
        [ 
          {env, [
                 {dispatch, Dispatch}
                ]},
          {compress,  true},
          {timeout,   12000}
        ],
    
    cowboy:start_http(web_interface_listener, ListenerCount, RanchOptions, CowboyOptions).
