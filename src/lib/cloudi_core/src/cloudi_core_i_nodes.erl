%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Nodes==
%%% Manage node connections to provide reliability after network interruptions.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2011-2019 Michael Truog <mjtruog at protonmail dot com>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a
%%% copy of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom the
%%% Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%%% DEALINGS IN THE SOFTWARE.
%%%
%%% @author Michael Truog <mjtruog at protonmail dot com>
%%% @copyright 2011-2019 Michael Truog
%%% @version 1.8.0 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_core_i_nodes).
-author('mjtruog at protonmail dot com').

-behaviour(gen_server).

%% external interface
-export([start_link/1,
         reconfigure/2,
         alive/1,
         dead/1,
         nodes/1,
         status/2,
         logging_redirect_set/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("cloudi_logger.hrl").
-include("cloudi_core_i_constants.hrl").
-include("cloudi_core_i_configuration.hrl").

-type nodes_up() ::
    #{node() :=
      {TimeStart :: cloudi_timestamp:native_monotonic(),
       TimeDisconnect :: undefined | cloudi_timestamp:native_monotonic(),
       Disconnects :: non_neg_integer()}}.

-record(state,
    {
        nodes_alive = [] :: list(node()),
        nodes_dead :: list(node()),
        nodes :: list(node()),
        nodes_up :: nodes_up(),
        nodes_down_durations = cloudi_core_i_status:durations_new()
            :: cloudi_core_i_status:durations(node()),
        logging_redirect :: node() | undefined,
        reconnect_interval :: pos_integer(),
        reconnect_timer :: reference(),
        listen :: visible | all,
        connect :: visible | hidden,
        discovery :: #config_nodes_discovery{} | undefined,
        cost :: #{node() | default := float()},
        cost_precision :: 0..253,
        log_reconnect :: cloudi_service_api:loglevel()
    }).

-define(CATCH_EXIT(F),
        try F catch exit:{Reason, _} -> {error, Reason} end).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

start_link(#config{nodes = #config_nodes{listen = Listen,
                                         connect = Connect,
                                         timestamp_type = TimestampType}} =
           Config) ->
    applications_set(Listen, Connect, TimestampType),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

reconfigure(Config, Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE, {reconfigure, Config}, Timeout)).

alive(Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE, alive, Timeout)).

dead(Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE, dead, Timeout)).

nodes(Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE, nodes, Timeout)).

status(NodesSelection, Timeout) ->
    ?CATCH_EXIT(gen_server:call(?MODULE, {status, NodesSelection}, Timeout)).

logging_redirect_set(Node) when is_atom(Node) ->
    gen_server:cast(?MODULE, {logging_redirect_set, Node}).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

init([#config{logging = #config_logging{redirect = NodeLogger},
              nodes = #config_nodes{nodes = Nodes,
                                    reconnect_start = ReconnectStart,
                                    reconnect_delay = ReconnectDelay,
                                    listen = Listen,
                                    connect = Connect,
                                    discovery = Discovery,
                                    cost = Cost,
                                    cost_precision = CostPrecision,
                                    log_reconnect = LogReconnect}}]) ->
    monitor_nodes(true, Listen),
    NodeLoggerNew = if
        NodeLogger == node(); NodeLogger =:= undefined ->
            undefined;
        true ->
            NodeLogger
    end,
    if
        NodeLoggerNew =/= undefined ->
            case lists:member(NodeLoggerNew, Nodes) of
                true ->
                    ok;
                false ->
                    ?LOG_WARN("unable to control log output redirection "
                              "to unmonitored node (~p)",
                              [NodeLoggerNew])
            end;
        true ->
            ok
    end,
    NodesUp = #{node() => {erlang:system_info(start_time), undefined, 0}},
    discovery_start(Discovery),
    ReconnectInterval = ReconnectDelay * 1000,
    ReconnectTimer = erlang:send_after(ReconnectStart * 1000,
                                       self(), reconnect),
    {ok, #state{nodes_dead = Nodes,
                nodes = Nodes,
                nodes_up = NodesUp,
                logging_redirect = NodeLoggerNew,
                reconnect_interval = ReconnectInterval,
                reconnect_timer = ReconnectTimer,
                listen = Listen,
                connect = Connect,
                discovery = Discovery,
                cost = maps:from_list(Cost),
                cost_precision = CostPrecision,
                log_reconnect = LogReconnect}}.

handle_call({reconfigure,
             #config{logging = #config_logging{redirect = NodeLogger},
                     nodes = #config_nodes{nodes = Nodes,
                                           reconnect_delay = ReconnectDelay,
                                           listen = Listen,
                                           connect = Connect,
                                           timestamp_type = TimestampType,
                                           discovery = Discovery,
                                           cost = Cost,
                                           cost_precision = CostPrecision,
                                           log_reconnect = LogReconnect}}}, _,
            #state{nodes_alive = NodesAlive,
                   nodes_up = NodesUp,
                   nodes_down_durations = NodesDownDurations,
                   listen = ListenOld,
                   connect = ConnectOld,
                   discovery = DiscoveryOld} = State) ->
    ConnectedNodes = if
        Connect =:= visible ->
            erlang:nodes();
        Connect =:= hidden ->
            erlang:nodes(connected)
    end,
    NodesNew = lists:usort(Nodes ++ ConnectedNodes),
    NodesDeadNew = lists:foldl(fun(N, L0) ->
        case cloudi_lists:delete_checked(N, L0) of
            false ->
                % node is alive, but is no longer configured
                net_kernel:disconnect(N),
                L0;
            LN ->
                LN
        end
    end, NodesNew, NodesAlive),
    NodesAliveNew = lists:filter(fun(N) ->
        not lists:member(N, NodesDeadNew)
    end, NodesNew),
    NodesUpNew = maps:with([node() | NodesNew], NodesUp),
    NodesDownDurationsNew = cloudi_core_i_status:
                            durations_copy(NodesNew, NodesDownDurations),
    ReconnectInterval = ReconnectDelay * 1000,
    logging_redirect_set(NodeLogger),
    applications_set(Listen, Connect, TimestampType),
    if
        ListenOld /= Listen ->
            monitor_nodes_switch(ListenOld, Listen),
            cpg_scopes_reset();
        true ->
            ok
    end,
    if
        ConnectOld /= Connect ->
            discovery_stop(DiscoveryOld),
            discovery_start(Discovery);
        true ->
            discovery_update(DiscoveryOld, Discovery)
    end,
    {reply, ok, State#state{nodes_alive = NodesAliveNew,
                            nodes_dead = NodesDeadNew,
                            nodes = NodesNew,
                            nodes_up = NodesUpNew,
                            nodes_down_durations = NodesDownDurationsNew,
                            reconnect_interval = ReconnectInterval,
                            connect = Connect,
                            discovery = Discovery,
                            cost = maps:from_list(Cost),
                            cost_precision = CostPrecision,
                            log_reconnect = LogReconnect}};

handle_call(alive, _,
            #state{nodes_alive = NodesAlive} = State) ->
    {reply, {ok, NodesAlive}, State};

handle_call(dead, _,
            #state{nodes_dead = NodesDead} = State) ->
    {reply, {ok, NodesDead}, State};

handle_call(nodes, _,
            #state{nodes = Nodes} = State) ->
    {reply, {ok, Nodes}, State};

handle_call({status, NodesSelection}, _,
            #state{nodes = Nodes,
                   nodes_up = NodesUp,
                   nodes_down_durations = NodesDownDurations,
                   cost = Cost,
                   cost_precision = CostPrecision} = State) ->
    TimeNow = cloudi_timestamp:native_monotonic(),
    NodesSelectionNew = if
        NodesSelection == [] ->
            lists:umerge(Nodes, [node()]);
        true ->
            NodesSelection
    end,
    Reply = nodes_status(NodesSelectionNew, TimeNow,
                         NodesDownDurations, NodesUp,
                         Cost, CostPrecision),
    {reply, Reply, State};

handle_call(Request, _, State) ->
    {stop, cloudi_string:format("Unknown call \"~w\"", [Request]),
     error, State}.

handle_cast({logging_redirect_set, NodeLogger},
            #state{nodes_alive = NodesAlive,
                   nodes_dead = NodesDead,
                   logging_redirect = NodeLoggerOld} = State) ->
    NodeLoggerNew = if
        NodeLogger == node(); NodeLogger =:= undefined ->
            undefined;
        true ->
            NodeLogger
    end,
    if
        NodeLoggerNew /= NodeLoggerOld ->
            if
                NodeLoggerNew =:= undefined ->
                    cloudi_core_i_logger:redirect_update(undefined);
                true ->
                    case lists:member(NodeLoggerNew, NodesAlive) of
                        true ->
                            cloudi_core_i_logger:redirect_update(NodeLoggerNew);
                        false ->
                            case lists:member(NodeLoggerNew, NodesDead) of
                                true ->
                                    ?LOG_INFO("redirecting log output to ~p "
                                              "after it reconnects",
                                              [NodeLoggerNew]);
                                false ->
                                    ?LOG_WARN("unable to redirect log output "
                                              "to an unmonitored node (~p)",
                                              [NodeLoggerNew])
                            end
                    end
            end,
            {noreply, State#state{logging_redirect = NodeLoggerNew}};
        true ->
            {noreply, State}
    end;

handle_cast(Request, State) ->
    {stop, cloudi_string:format("Unknown cast \"~w\"", [Request]), State}.

handle_info({nodeup, Node, InfoList},
            #state{logging_redirect = NodeLogger} = State) ->
    if
        Node == NodeLogger ->
            cloudi_core_i_logger:redirect_update(NodeLogger);
        true ->
            ok
    end,
    ?LOG_INFO("nodeup ~p~n ~p", [Node, InfoList]),
    {noreply, track_nodeup(Node, State)};

handle_info({nodedown, Node, InfoList},
            #state{logging_redirect = NodeLogger} = State) ->
    if
        Node == NodeLogger ->
            cloudi_core_i_logger:redirect_update(undefined);
        true ->
            ok
    end,
    ?LOG_INFO("nodedown ~p~n ~p", [Node, InfoList]),
    {noreply, track_nodedown(Node, State)};

handle_info(reconnect,
            #state{nodes_dead = NodesDead,
                   reconnect_interval = ReconnectInterval,
                   connect = Connect,
                   discovery = Discovery,
                   log_reconnect = LogReconnect} = State) ->
    discovery_check(Discovery),
    if
        NodesDead /= [] ->
            ?LOG(LogReconnect, "currently dead nodes ~p", [NodesDead]),
            pforeach(fun(Node) ->
                % avoid the possibly long synchronous call here
                connect_node(Connect, Node)
            end, NodesDead);
        true ->
            ok
    end,
    ReconnectTimer = erlang:send_after(ReconnectInterval, self(), reconnect),
    {noreply, State#state{reconnect_timer = ReconnectTimer}};

handle_info({ReplyRef, _}, State) when is_reference(ReplyRef) ->
    % gen_server:call/3 had a timeout exception that was caught but the
    % reply arrived later and must be discarded
    {noreply, State};

handle_info(Request, State) ->
    {stop, cloudi_string:format("Unknown info \"~w\"", [Request]), State}.

terminate(_, #state{discovery = Discovery}) ->
    discovery_stop(Discovery),
    ok.

code_change(_, State, _) ->
    {ok, State}.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

applications_set(Listen, Connect, TimestampType) ->
    application:set_env(cloudi_x_cpg, node_type, Listen),
    application:set_env(cloudi_x_nodefinder, node_type, Connect),
    application:set_env(cloudi_core, timestamp_type, TimestampType),
    ok.

monitor_nodes(Flag, Listen) ->
    net_kernel:monitor_nodes(Flag, [{node_type, Listen}, nodedown_reason]).

monitor_nodes_switch(ListenOld, ListenNew) ->
    % may cause duplicate nodeup/nodedown messages to avoid ignoring events
    monitor_nodes(true, ListenNew),
    monitor_nodes(false, ListenOld).

track_nodeup(Node,
             #state{nodes_alive = NodesAlive,
                    nodes_dead = NodesDead,
                    nodes = Nodes,
                    nodes_up = NodesUp,
                    nodes_down_durations = NodesDownDurations} = State) ->
    TimeUp = cloudi_timestamp:native_monotonic(),
    NodeL = [Node],
    {NodesUpNew,
     NodesDownDurationsNew} = case maps:find(Node, NodesUp) of
        {ok, {_, undefined, _}} ->
            {NodesUp, NodesDownDurations}; % duplicate nodeup
        {ok, {TimeStart, TimeDisconnect, Disconnects}} ->
            Duration = {TimeDisconnect, TimeUp},
            {maps:put(Node, {TimeStart, undefined, Disconnects}, NodesUp),
             cloudi_core_i_status:
             durations_store(NodeL, Duration, NodesDownDurations)};
        error ->
            {maps:put(Node, {TimeUp, undefined, 0}, NodesUp),
             NodesDownDurations}
    end,
    State#state{nodes_alive = lists:umerge(NodesAlive, NodeL),
                nodes_dead = lists:delete(Node, NodesDead),
                nodes = lists:umerge(Nodes, NodeL),
                nodes_up = NodesUpNew,
                nodes_down_durations = NodesDownDurationsNew}.

track_nodedown(Node,
               #state{nodes_alive = NodesAlive,
                      nodes_dead = NodesDead,
                      nodes_up = NodesUp} = State) ->
    TimeDisconnect = cloudi_timestamp:native_monotonic(),
    NodesUpNew = case maps:find(Node, NodesUp) of
        {ok, {TimeStart, undefined, Disconnects}} ->
            maps:put(Node,
                     {TimeStart, TimeDisconnect, Disconnects + 1}, NodesUp);
        _ ->
            NodesUp % duplicate nodedown
    end,
    State#state{nodes_alive = lists:delete(Node, NodesAlive),
                nodes_dead = lists:umerge(NodesDead, [Node]),
                nodes_up = NodesUpNew}.

nodes_status(NodesSelection, TimeNow, NodesDownDurations, NodesUp,
             Cost, CostPrecision) ->
    TimeDayStart = TimeNow - ?NATIVE_TIME_IN_DAY,
    TimeWeekStart = TimeNow - ?NATIVE_TIME_IN_WEEK,
    TimeMonthStart = TimeNow - ?NATIVE_TIME_IN_MONTH,
    TimeYearStart = TimeNow - ?NATIVE_TIME_IN_YEAR,
    CostDefault = maps:get(default, Cost, undefined),
    nodes_status(NodesSelection, [], TimeNow, TimeDayStart, TimeWeekStart,
                 TimeMonthStart, TimeYearStart, NodesDownDurations, NodesUp,
                 Cost, CostDefault, CostPrecision).

nodes_status([], StatusList, _, _, _, _, _, _, _, _, _, _) ->
    {ok, lists:reverse(StatusList)};
nodes_status([Node | NodesSelection], StatusList, TimeNow,
             TimeDayStart, TimeWeekStart,
             TimeMonthStart, TimeYearStart,
             NodesDownDurations, NodesUp,
             Cost, CostDefault, CostPrecision) ->
    case maps:find(Node, NodesUp) of
        {ok, {TimeStart, TimeDisconnect, Disconnects}} ->
            LocalNode = Node =:= node(),
            {Disconnected,
             NodesDownDurationsTmp} = if
                TimeDisconnect =:= undefined ->
                    {false, NodesDownDurations};
                is_integer(TimeDisconnect) ->
                    % track ongoing downtime with a temporary duration
                    {true,
                     cloudi_core_i_status:
                     durations_store([Node], {TimeDisconnect, TimeNow},
                                     NodesDownDurations)}
            end,
            DurationsStateDown = cloudi_core_i_status:
                                 durations_state(Node, NodesDownDurationsTmp),
            NanoSeconds = cloudi_timestamp:
                          convert(TimeNow - TimeStart, native, nanosecond),
            Uptime = cloudi_timestamp:
                     nanoseconds_to_string(NanoSeconds),
            {ApproximateYearDisconnect,
             NanoSecondsYearDisconnect} = cloudi_core_i_status:
                                          durations_sum(DurationsStateDown,
                                                        TimeYearStart),
            {ApproximateMonthDisconnect,
             NanoSecondsMonthDisconnect} = cloudi_core_i_status:
                                           durations_sum(DurationsStateDown,
                                                         TimeMonthStart),
            {ApproximateWeekDisconnect,
             NanoSecondsWeekDisconnect} = cloudi_core_i_status:
                                          durations_sum(DurationsStateDown,
                                                        TimeWeekStart),
            {ApproximateDayDisconnect,
             NanoSecondsDayDisconnect} = cloudi_core_i_status:
                                         durations_sum(DurationsStateDown,
                                                       TimeDayStart),
            Status0 = [],
            Status1 = case cloudi_core_i_status:
                           nanoseconds_to_availability_year(
                               NanoSeconds,
                               ApproximateYearDisconnect,
                               NanoSecondsYearDisconnect) of
                ?AVAILABILITY_ZERO ->
                    Status0;
                AvailabilityYear ->
                    [{availability_year,
                      AvailabilityYear} | Status0]
            end,
            Status2 = case cloudi_core_i_status:
                           nanoseconds_to_availability_month(
                               NanoSeconds,
                               ApproximateMonthDisconnect,
                               NanoSecondsMonthDisconnect) of
                ?AVAILABILITY_ZERO ->
                    Status1;
                AvailabilityMonth ->
                    [{availability_month,
                      AvailabilityMonth} | Status1]
            end,
            Status3 = case cloudi_core_i_status:
                           nanoseconds_to_availability_week(
                               NanoSeconds,
                               ApproximateWeekDisconnect,
                               NanoSecondsWeekDisconnect) of
                ?AVAILABILITY_ZERO ->
                    Status2;
                AvailabilityWeek ->
                    [{availability_week,
                      AvailabilityWeek} | Status2]
            end,
            Status4 = [{availability_day,
                        cloudi_core_i_status:
                        nanoseconds_to_availability_day(
                            NanoSeconds,
                            ApproximateDayDisconnect,
                            NanoSecondsDayDisconnect)} | Status3],
            Status5 = if
                TimeStart =< TimeMonthStart,
                NanoSecondsYearDisconnect > 0 ->
                    [{downtime_year_disconnected,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsYearDisconnect,
                                            ApproximateYearDisconnect)} |
                     Status4];
                true ->
                    Status4
            end,
            Status6 = if
                TimeStart =< TimeWeekStart,
                NanoSecondsMonthDisconnect > 0 orelse
                NanoSecondsYearDisconnect > 0 ->
                    [{downtime_month_disconnected,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsMonthDisconnect,
                                            ApproximateMonthDisconnect)} |
                     Status5];
                true ->
                    Status5
            end,
            Status7 = if
                TimeStart =< TimeDayStart,
                NanoSecondsWeekDisconnect > 0 orelse
                NanoSecondsMonthDisconnect > 0 orelse
                NanoSecondsYearDisconnect > 0 ->
                    [{downtime_week_disconnected,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsWeekDisconnect,
                                            ApproximateWeekDisconnect)} |
                     Status6];
                true ->
                    Status6
            end,
            Status8 = if
                NanoSecondsDayDisconnect > 0 orelse
                NanoSecondsWeekDisconnect > 0 orelse
                NanoSecondsMonthDisconnect > 0 ->
                    [{downtime_day_disconnected,
                      cloudi_core_i_status:
                      nanoseconds_to_string(NanoSecondsDayDisconnect,
                                            ApproximateDayDisconnect)} |
                     Status7];
                true ->
                    Status7
            end,
            Status9 = if
                LocalNode =:= true ->
                    Status8;
                LocalNode =:= false ->
                    [{tracked_disconnects,
                      erlang:integer_to_list(Disconnects)},
                     {disconnected, Disconnected} | Status8]
            end,
            Status10 = node_status_cost(maps:get(Node, Cost, CostDefault),
                                        NanoSeconds, CostPrecision,
                                        LocalNode, Status9),
            StatusN = if
                LocalNode =:= true ->
                    [{uptime, Uptime} | Status10];
                LocalNode =:= false ->
                    [{tracked, Uptime} | Status10]
            end,
            nodes_status(NodesSelection,
                         [{Node, StatusN} | StatusList], TimeNow,
                         TimeDayStart, TimeWeekStart,
                         TimeMonthStart, TimeYearStart,
                         NodesDownDurations, NodesUp,
                         Cost, CostDefault, CostPrecision);
        error ->
            {error, {node_not_found, Node}}
    end.

node_status_cost(undefined, _, _, _, Status0) ->
    Status0;
node_status_cost(CostValue, NanoSeconds, CostPrecision, LocalNode, Status0) ->
    Hours = NanoSeconds / ?NANOSECONDS_IN_HOUR,
    Days = Hours / ?HOURS_IN_DAY,
    Weeks = Days / ?DAYS_IN_WEEK,
    Months = Days / ?DAYS_IN_MONTH,
    Years = Days / ?DAYS_IN_YEAR,
    CostCurrency = Hours * CostValue,
    Status1 = if
        Years >= 1.0 ->
            CostNameYear = if
                LocalNode =:= true ->
                    uptime_cost_year;
                LocalNode =:= false ->
                    tracked_cost_year
            end,
            [{CostNameYear,
              erlang:float_to_list(CostCurrency / Years,
                                   [{decimals, CostPrecision}])} | Status0];
        true ->
            Status0
    end,
    Status2 = if
        Months >= 1.0 ->
            CostNameMonth = if
                LocalNode =:= true ->
                    uptime_cost_month;
                LocalNode =:= false ->
                    tracked_cost_month
            end,
            [{CostNameMonth,
              erlang:float_to_list(CostCurrency / Months,
                                   [{decimals, CostPrecision}])} | Status1];
        true ->
            Status1
    end,
    Status3 = if
        Weeks >= 1.0 ->
            CostNameWeek = if
                LocalNode =:= true ->
                    uptime_cost_week;
                LocalNode =:= false ->
                    tracked_cost_week
            end,
            [{CostNameWeek,
              erlang:float_to_list(CostCurrency / Weeks,
                                   [{decimals, CostPrecision}])} | Status2];
        true ->
            Status2
    end,
    StatusN = if
        Days >= 1.0 ->
            CostNameDay = if
                LocalNode =:= true ->
                    uptime_cost_day;
                LocalNode =:= false ->
                    tracked_cost_day
            end,
            [{CostNameDay,
              erlang:float_to_list(CostCurrency / Days,
                                   [{decimals, CostPrecision}])} | Status3];
        true ->
            Status3
    end,
    CostNameTotal = if
        LocalNode =:= true ->
            uptime_cost_total;
        LocalNode =:= false ->
            tracked_cost_total
    end,
    [{CostNameTotal,
      erlang:float_to_list(CostCurrency,
                           [{decimals, CostPrecision}])} | StatusN].

discovery_start_args(ec2_discover, StartA) ->
    [EC2AccessKeyId, EC2SecretAccessKey,
     EC2Host, EC2Groups, EC2Tags] = StartA,
    Environment = cloudi_environment:lookup(),
    [cloudi_environment:transform(EC2AccessKeyId, Environment),
     cloudi_environment:transform(EC2SecretAccessKey, Environment),
     cloudi_environment:transform(EC2Host, Environment),
     EC2Groups, EC2Tags];
discovery_start_args(_, StartA) ->
    StartA.

discovery_start(undefined) ->
    ok;
discovery_start(#config_nodes_discovery{module = Module,
                                        start_f = StartF,
                                        start_a = StartA}) ->
    case erlang:apply(Module, StartF, discovery_start_args(StartF, StartA)) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("~p:~p error: ~p", [Module, StartF, Reason])
    end,
    ok.

discovery_check(undefined) ->
    ok;
discovery_check(#config_nodes_discovery{module = Module,
                                        discover_f = DiscoverF,
                                        discover_a = DiscoverA}) ->
    case erlang:apply(Module, DiscoverF, DiscoverA) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("~p:~p error: ~p", [Module, DiscoverF, Reason])
    end,
    ok.

discovery_stop(undefined) ->
    ok;
discovery_stop(#config_nodes_discovery{module = Module,
                                       stop_f = StopF,
                                       stop_a = StopA}) ->
    case erlang:apply(Module, StopF, StopA) of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("~p:~p error: ~p", [Module, StopF, Reason])
    end,
    ok.

discovery_update(undefined, undefined) ->
    ok;
discovery_update(undefined, #config_nodes_discovery{} = DiscoveryNew) ->
    discovery_start(DiscoveryNew);
discovery_update(#config_nodes_discovery{} = DiscoveryOld, undefined) ->
    discovery_stop(DiscoveryOld);
discovery_update(#config_nodes_discovery{start_f = StartF,
                                         start_a = StartA},
                 #config_nodes_discovery{start_f = StartF,
                                         start_a = StartA}) ->
    ok;
discovery_update(#config_nodes_discovery{} = DiscoveryOld,
                 #config_nodes_discovery{} = DiscoveryNew) ->
    discovery_stop(DiscoveryOld),
    discovery_start(DiscoveryNew).

cpg_scopes() ->
    % due to settings in cloudi_core_i_constants.hrl of
    % SCOPE_CUSTOM_PREFIX and SCOPE_DEFAULT
    CustomScopes = lists:filter(fun(RegisteredName) ->
        lists:prefix(?SCOPE_CUSTOM_PREFIX,
                     erlang:atom_to_list(RegisteredName))
    end, erlang:registered()),
    [?SCOPE_DEFAULT | CustomScopes].

cpg_scopes_reset() ->
    lists:foreach(fun(Scope) ->
        cloudi_x_cpg:reset(Scope)
    end, cpg_scopes()).

connect_node(visible, Node) ->
    net_kernel:connect_node(Node);
connect_node(hidden, Node) ->
    net_kernel:hidden_connect_node(Node).

pforeach(_, []) ->
    ok;
pforeach(F, L) ->
    [erlang:spawn_link(fun() -> F(E) end) || E <- L],
    ok.
