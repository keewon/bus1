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
          id,
          bus_loc_list=[],
          created_at,
          loc_updated_at,
          last_error,
          route_updated_at,
          route_raw,
          bus_first_time,
          station_array
         }).

-define(INTERVAL_LOC_1, 1000). % TODO: random interval
-define(INTERVAL_ROUTE_1, 1000). % TODO: random interval
%-define(INTERVAL, 30000). % 10 * 1000
-define(INTERVAL_LOC, 180000). % 3 * 60 * 1000
-define(INTERVAL_ROUTE, 3600000). % 60 * 60 * 1000
-define(TIME_DIFF_RETIRE, 86400000). % 86400 * 1000 * 1000
-define(LOC_URL, "http://api.pubtrans.map.naver.com/2.1/live/getBusLocation.jsonp?caller=pc_map&routeId=").
-define(ROUTE_URL, "http://map.naver.com/pubtrans/getBusRouteInfo.nhn?busID=").

%% API.

%-spec start_link() -> {ok, pid()}.
start_link(BusId) ->
    LId = binary_to_list(BusId),
    AId = list_to_atom("worker_" ++ LId),
    gen_server:start_link({local, AId}, ?MODULE, [BusId], []).

%% gen_server.

init([BusId]) ->
    erlang:send_after(get_first_loc_interval(), self(), check),
    {ok, #state{id=BusId, created_at=os:timestamp()}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(debug, State) ->
    lager:debug("~p", [State]),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check, #state{
                      id=BusId, last_error=LastError,
                      created_at=CreatedAt, loc_updated_at=LocUpdatedAt
                     } = State) ->
    lager:debug("check location ~p", [BusId]),
    case catch check_location(State) of
        #state{} = NewState -> 
            erlang:send_after(get_loc_interval(), self(), check),
            {noreply, NewState#state{last_error = undefined}};
        {'EXIT', Reason} ->
            % Output error reason
            case Reason of
                LastError ->
                    lager:debug("id: ~p, error: ~p", [BusId, Reason]);
                _ ->
                    lager:warning("Id: ~p, error: ~p", [BusId, Reason])
            end,

            % Check validity
            Now = os:timestamp(),
            LastValid = case LocUpdatedAt of
                            undefined -> CreatedAt;
                            _ -> LocUpdatedAt
                        end,
            case timer:now_diff(Now, LastValid) >= ?TIME_DIFF_RETIRE * 1000 of
                true ->
                    {stop, {retire, Reason}, State};
                _ ->
                    erlang:send_after(get_loc_interval(), self(), check),
                    {noreply, State#state{last_error = Reason}}
            end
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%

check_location(#state{
                  id=BusId,
                  bus_loc_list=OldBusLocationList
                 } = State) ->
    {ok, {{_NewVersion, 200, _NewReasonPhrase}, _NewHeaders, NewBody}} =
        httpc:request(get, {get_loc_url(BusId), [{"User-Agent", "Mozilla/5.0"}]}, [], []),
    BBody = list_to_binary(NewBody),
    Json = jsx:decode(BBody),
    % message/result/busLocationList
    Message = proplists:get_value(<<"message">>, Json),
    Result = proplists:get_value(<<"result">>, Message),
    BusLocationList = proplists:get_value(<<"busLocationList">>, Result),

    {Obsoletes, NewBusLocationList} = update_bus_loc_list(OldBusLocationList, BusLocationList),

    NewState = case Obsoletes of
                   [] -> State;
                   _ ->
                       check_route(State)
               end,

    case Obsoletes of
        [] -> ok;
        _ ->
            lists:foreach(
                fun({PlateNo, [{_, LastUpdateDate}|_] = History}) ->
                    % File name format: {BusId}/{Year}/{Month}{Day}.txt
                    {Year, Month, Day, _, _, _} = split_update_date(LastUpdateDate),
                    Path = ["data", binary_to_list(BusId), Year, Month],
                    mkdir_p(Path, []),
                    FileName = string:join(Path, "/") ++ "/" ++ Day ++ ".txt",
                    {ok, IoDevice} = file:open(FileName, [append, {encoding, utf8}]),
                    io:format(IoDevice, "{ \"~ts\" : [~ts]},~n",
                              [PlateNo,
                               io_format_history(
                                 History, {Month, Day}, NewState#state.station_array)]),
                    ok = file:close(IoDevice)
                end, Obsoletes)
    end,

    NewState#state{ bus_loc_list=NewBusLocationList, loc_updated_at=os:timestamp()}.


update_bus_loc_list(OldBusLocationList, BusLocationList) ->
    lists:foldl(
    fun(BusLocation, {OldList, NewList}) ->
        StationSeq = proplists:get_value(<<"stationSeq">>, BusLocation),
        UpdateDate = proplists:get_value(<<"updateDate">>, BusLocation),
        PlateNo    = proplists:get_value(<<"plateNo">>, BusLocation),

        {OldListUpdated, NewData} =
            case lists:keytake(PlateNo, 1, OldList) of
                {value, {_, [{LastStationSeq, _LastUpdateDate}|_]=History}, OldListUpdated1} ->
                    if
                        StationSeq < (LastStationSeq - 2) -> % some buses go back to previous station
                            % New bus
                            { [ {PlateNo, History} | OldListUpdated1], {PlateNo, [{StationSeq, UpdateDate}]} };
                        true ->
                            % Update bus
                            { OldListUpdated1, {PlateNo, [{StationSeq, UpdateDate} | History]} }
                            % No update
                            % { OldListUpdated1, {PlateNo, History} }
                    end;
                false -> 
                    % New bus
                    { OldList, {PlateNo, [{StationSeq, UpdateDate}]} }
            end,
        { OldListUpdated, [NewData | NewList] }
    end, {OldBusLocationList, []}, BusLocationList).

check_route(#state{route_updated_at=undefined, last_error=undefined}=State) ->
    check_route1(State);

check_route(#state{route_updated_at=RouteUpdatedAt, last_error=undefined}=State) ->
    case timer:now_diff(os:timestamp(), RouteUpdatedAt) >= ?INTERVAL_ROUTE of
        true ->
            check_route1(State);
        _ ->
            State
    end;

check_route(State) ->
    check_route1(State).

check_route1(#state{id=BusId, route_raw=RouteRaw} = State) ->
    lager:debug("check route ~p", [BusId]),

    {ok, {{_NewVersion, 200, _NewReasonPhrase}, _NewHeaders, NewBody}} =
        httpc:request(get, {get_route_url(BusId), [{"User-Agent", "Mozilla/5.0"}]}, [], []),
    BBody = list_to_binary(NewBody),

    case BBody of
        RouteRaw -> State;
        _ ->
            Json = jsx:decode(BBody),
            Result = proplists:get_value(<<"result">>, Json),
            BusFirstTimeRaw = proplists:get_value(<<"busFirstTime">>, Result),
            BusFirstTime = case BusFirstTimeRaw of
                BusFirstTimeBinary when is_binary(BusFirstTimeBinary) ->
                    BusFirstTimeList = binary_to_list(BusFirstTimeBinary),
                    case BusFirstTimeList of
                        [H1, H2, $:, M1, M2] ->
                            { [H1, H2], [M1, M2] };
                        _ ->
                            undefined
                    end;
                _ -> undefined
            end,
            Stations = proplists:get_value(<<"station">>, Result),
            StationLen = length(Stations),
            StationArray0 = array:new([{size,StationLen}, {fixed, false}, {default, <<"">>}]),
            {StationArray, _} = lists:foldl(
                                fun(Station, {Array, Index}) ->
                                        Name = proplists:get_value(<<"stationName">>, Station),
                                        {array:set(Index, Name, Array), Index+1}
                                end, {StationArray0, 0}, Stations),
            lager:info("route changed ~p", [BusId]),
            State#state{
              station_array=StationArray,
              route_raw=BBody,
              bus_first_time=BusFirstTime,
              route_updated_at=os:timestamp()
             }
    end.

io_format_history(History, MonthDay, StationArray) ->
    io_format_history(History, [], MonthDay, StationArray).

io_format_history([], Result, _MonthDay, _StationArray) ->
    Result;
io_format_history([{Location, UpdateDate}|Tail], Result, MonthDay, StationArray) ->
    StationName = array:get(Location, StationArray),
    io_format_history(Tail,
                      [[<<"{\"">>, integer_to_list(Location), <<"\":">>,
                        <<"{\"t\":\"">>, format_date(UpdateDate, MonthDay), <<"\",">>,
                        <<"\"n\":\"">>, StationName, <<"\"}},">> ] | Result],
                      MonthDay, StationArray).

format_date(UpdateDate, {MonthRef, DayRef}) ->
    {Year, Month, Day, Hour, Minute, Second} = split_update_date(UpdateDate),
    case {Month, Day} of
        {MonthRef, DayRef} -> [Hour, ":", Minute, ":", Second];
        _ -> [Year, "-", Month, "-", Day, " ", Hour, ":", Minute, ":", Second]
    end.

% 20140818003817 -> {"2014", "08", "18", "00", "38", "17"}
split_update_date(DateStr) ->
    Year = (binary_to_list(binary:part(DateStr, 0, 4))),
    Month = (binary_to_list(binary:part(DateStr, 4, 2))),
    Day = (binary_to_list(binary:part(DateStr, 6, 2))),
    Hour = (binary_to_list(binary:part(DateStr, 8, 2))),
    Minute = (binary_to_list(binary:part(DateStr, 10, 2))),
    Second = (binary_to_list(binary:part(DateStr, 12, 2))),

    {Year, Month, Day, Hour, Minute, Second}.

mkdir_p([], _) -> ok;
mkdir_p([H|T], []) ->
    file:make_dir(H),
    mkdir_p(T, H);
mkdir_p([H|T], Parents) ->
    Path = Parents ++ "/" ++ H,
    file:make_dir(Path),
    mkdir_p(T, Path).

get_loc_url(BusId) ->
    ?LOC_URL ++ binary_to_list(BusId).

get_route_url(BusId) ->
    ?ROUTE_URL ++ binary_to_list(BusId).

get_first_loc_interval() ->
    ?INTERVAL_LOC_1.

get_loc_interval() ->
    ?INTERVAL_LOC.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

update_bus_loc_list_test() ->
    A = [ {1, [{10,<<"20090101000000">>}]} ],
    B = [[ {<<"plateNo">>, 1}, {<<"stationSeq">>, 10}, {<<"updateDate">>, <<"20090101000010">>}]],
    C = [[ {<<"plateNo">>, 1}, {<<"stationSeq">>, 12}, {<<"updateDate">>, <<"20090101000010">>}]],
    D = [[ {<<"plateNo">>, 1}, {<<"stationSeq">>, 1}, {<<"updateDate">>, <<"20090101000010">>}]],

    {ABO, ABN} = update_bus_loc_list(A, B),

    ?assertEqual([], ABO),
    ?assertEqual(A, ABN),

    {ACO, ACN} = update_bus_loc_list(A, C),

    ?assertEqual([], ACO),
    ?assertEqual([ {1, [{12, <<"20090101000010">>}, {10, <<"20090101000000">>} ]}], ACN),


    {ADO, ADN} = update_bus_loc_list(A, D),

    ?assertEqual([{1, [{10, <<"20090101000000">>}]}], ADO),
    ?assertEqual([{1, [{1, <<"20090101000010">>}]}], ADN).

worker_tests() ->
    update_bus_loc_list_test().

-endif.
