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
          get_url,
          bus_location_list=[],
          created_at,
          updated_at,
          last_error
         }).

-define(FIRST_INTERVAL, 1000). % TODO: random interval
%-define(INTERVAL, 30000). % 10 * 1000
-define(INTERVAL, 180000). % 3 * 60 * 1000
-define(TIME_DIFF_RETIRE, 86400000). % 86400 * 1000 * 1000
-define(URL, "http://api.pubtrans.map.naver.com/2.1/live/getBusLocation.jsonp?caller=pc_map&routeId=").
%-define(URL, "http://localhost").

%% API.

%-spec start_link() -> {ok, pid()}.
start_link(BusId) ->
    LId = binary_to_list(BusId),
    AId = list_to_atom("worker_" ++ LId),
    gen_server:start_link({local, AId}, ?MODULE, [BusId], []).

%% gen_server.

init([BusId]) ->
    LBusId = binary_to_list(BusId),
    GetUrl = list_to_binary( ?URL ++ LBusId ),
    erlang:send_after(?FIRST_INTERVAL, self(), check),
    {ok, #state{id=BusId, get_url=GetUrl, created_at=os:timestamp()}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check, #state{
                      id=BusId, last_error=LastError,
                      created_at=CreatedAt, updated_at=UpdatedAt} = State) ->
    lager:debug("check bus ~p", [BusId]),
    case catch check_bus(State) of
        #state{} = NewState -> 
            erlang:send_after(?INTERVAL, self(), check),
            {noreply, NewState};
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
            LastValid = case UpdatedAt of
                            undefined -> CreatedAt;
                            _ -> UpdatedAt
                        end,
            case timer:now_diff(Now, LastValid) >= ?TIME_DIFF_RETIRE * 1000 of
                true ->
                    {stop, {retire, Reason}, State};
                _ ->
                    erlang:send_after(?INTERVAL, self(), check),
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

check_bus(#state{id=BusId, get_url=GetUrl, bus_location_list=OldBusLocationList} = State) ->
    {ok, {{_NewVersion, 200, _NewReasonPhrase}, _NewHeaders, NewBody}} =
        httpc:request(get, {binary_to_list(GetUrl), [{"User-Agent", "Mozilla/5.0"}]}, [], []),
    BBody = list_to_binary(NewBody),
    Json = jsx:decode(BBody),
    % message/result/busLocationList
    Message = proplists:get_value(<<"message">>, Json),
    Result = proplists:get_value(<<"result">>, Message),
    BusLocationList = proplists:get_value(<<"busLocationList">>, Result),

    {Obsoletes, NewBusLocationList} = update_bus_location_list(OldBusLocationList, BusLocationList),

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
                    io:format(IoDevice, "{ \"~ts\" : [~ts]},~n", [PlateNo, io_format_history(History, {Month, Day})]),
                    ok = file:close(IoDevice)
                end, Obsoletes)
    end,

    State#state{ bus_location_list=NewBusLocationList, updated_at=os:timestamp()}.


update_bus_location_list(OldBusLocationList, BusLocationList) ->
    lists:foldl(
    fun(BusLocation, {OldList, NewList}) ->
        StationSeq = proplists:get_value(<<"stationSeq">>, BusLocation),
        UpdateDate = proplists:get_value(<<"updateDate">>, BusLocation),
        PlateNo    = proplists:get_value(<<"plateNo">>, BusLocation),

        {OldListUpdated, NewData} =
            case lists:keytake(PlateNo, 1, OldList) of
                {value, {_, [{LastStationSeq, _LastUpdateDate}|_]=History}, OldListUpdated1} ->
                    if
                        StationSeq > LastStationSeq ->
                            % Update bus
                            { OldListUpdated1, {PlateNo, [{StationSeq, UpdateDate} | History]} };
                        StationSeq < LastStationSeq ->
                            % New bus
                            { [ {PlateNo, History} | OldListUpdated1], {PlateNo, [{StationSeq, UpdateDate}]} };
                        true ->
                            % No update
                            { OldListUpdated1, {PlateNo, History} }
                    end;
                false -> 
                    % New bus
                    { OldList, {PlateNo, [{StationSeq, UpdateDate}]} }
            end,
        { OldListUpdated, [NewData | NewList] }
    end, {OldBusLocationList, []}, BusLocationList).

io_format_history(History, MonthDay) ->
    io_format_history(History, [], MonthDay).

io_format_history([], Result, _MonthDay) ->
    Result;
io_format_history([{Location, UpdateDate}|Tail], Result, MonthDay) ->
    io_format_history(Tail,
                      [[<<"{\"">>, integer_to_list(Location), <<"\":">>,
                        <<"\"">>, format_date(UpdateDate, MonthDay), <<"\"},">> ] | Result], MonthDay).

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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

update_bus_location_list_test() ->
    A = [ {1, [{10,<<"20090101000000">>}]} ],
    B = [[ {<<"plateNo">>, 1}, {<<"stationSeq">>, 10}, {<<"updateDate">>, <<"20090101000010">>}]],
    C = [[ {<<"plateNo">>, 1}, {<<"stationSeq">>, 12}, {<<"updateDate">>, <<"20090101000010">>}]],
    D = [[ {<<"plateNo">>, 1}, {<<"stationSeq">>, 1}, {<<"updateDate">>, <<"20090101000010">>}]],

    {ABO, ABN} = update_bus_location_list(A, B),

    ?assertEqual([], ABO),
    ?assertEqual(A, ABN),

    {ACO, ACN} = update_bus_location_list(A, C),

    ?assertEqual([], ACO),
    ?assertEqual([ {1, [{12, <<"20090101000010">>}, {10, <<"20090101000000">>} ]}], ACN),


    {ADO, ADN} = update_bus_location_list(A, D),

    ?assertEqual([{1, [{10, <<"20090101000000">>}]}], ADO),
    ?assertEqual([{1, [{1, <<"20090101000010">>}]}], ADN).

worker_tests() ->
    update_bus_location_list_test().

-endif.
