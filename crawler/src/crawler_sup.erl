-module(crawler_sup).
-behaviour(supervisor).
-include("crawler.hrl").

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Procs = [],
    lager:info("hello!", []),
    {ok, {{one_for_one, 1, 5}, Procs}}.
