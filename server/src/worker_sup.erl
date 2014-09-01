-module(worker_sup).
-behaviour(supervisor).
-include("bus_archive.hrl").

-export([start_link/0, add_child/1, remove_child/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{simple_one_for_one, 10, 3600},
          [{worker_sup,
            {worker, start_link, []},
            permanent, 1000, worker, [worker]}
          ]}}.

add_child(BusId) ->
    supervisor:start_child(?MODULE, [BusId]).

remove_child(_BusId) ->
    todo.
