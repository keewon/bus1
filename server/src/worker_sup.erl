-module(worker_sup).
-behaviour(supervisor).
-include("bus_archive.hrl").

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{simple_one_for_one, 3, 60},
          [{worker_sup,
            {worker, start_link, []},
            temporary, 1000, worker, [worker]}
          ]}}.
