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
          bus_location_list=[]
         }).

-define(FIRST_INTERVAL, 1000).
-define(INTERVAL, 30000). % 5 * 60 * 1000
%-define(INTERVAL, 300000). % 5 * 60 * 1000
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
    GetUrl = list_to_binary( ?URL ++ binary_to_list(BusId) ),
    erlang:send_after(?FIRST_INTERVAL, self(), check),
    {ok, #state{id=BusId, get_url=GetUrl}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check, #state{id=BusId, get_url=GetUrl, bus_location_list=OldBusLocationList} = State) ->
    lager:info("check bus ~p", [BusId]),
    {ok, {{_NewVersion, 200, _NewReasonPhrase}, _NewHeaders, NewBody}} =
        httpc:request(get, {binary_to_list(GetUrl), [{"User-Agent", "Mozilla/5.0"}]}, [], []),
    BBody = list_to_binary(NewBody),
    Json = jsx:decode(BBody),
    % message/result/busLocationList
    Message = proplists:get_value(<<"message">>, Json),
    Result = proplists:get_value(<<"result">>, Message),
    BusLocationList = proplists:get_value(<<"busLocationList">>, Result),

    {Obsoletes, NewBusLocationList} = lists:foldl(
        fun(BusLocation, {OldList, NewList}) ->
            StationSeq = proplists:get_value(<<"stationSeq">>, BusLocation),
            UpdateDate = proplists:get_value(<<"updateDate">>, BusLocation),
            PlateNo    = proplists:get_value(<<"plateNo">>, BusLocation),

            lager:info("~ts, ~p, ~s", [PlateNo, StationSeq, UpdateDate]),

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
            {OldListUpdated, [NewData | NewList]}
        end, {OldBusLocationList, []}, BusLocationList),

    lager:info("obsoletes: ~p", [Obsoletes]),
    lager:info("new: ~p", [NewBusLocationList]),

    erlang:send_after(?INTERVAL, self(), check),
    {noreply, State#state{ bus_location_list=NewBusLocationList} };
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%

% 20140818003817
%date_to_timestamp(DateStr) ->
%    Year = list_to_integer(binary_to_list(binary:part(DateStr, 0, 4))),
%    Month = list_to_integer(binary_to_list(binary:part(DateStr, 4, 2))),
%    Day = list_to_integer(binary_to_list(binary:part(DateStr, 6, 2))),
%    Hour = list_to_integer(binary_to_list(binary:part(DateStr, 8, 2))),
%    Minute = list_to_integer(binary_to_list(binary:part(DateStr, 10, 2))),
%    Second = list_to_integer(binary_to_list(binary:part(DateStr, 12, 2))),
%
%    lager:info("~p ~p ~p ~p ~p ~p", [Year, Month, Day, Hour, Minute, Second]).

