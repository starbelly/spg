%%-------------------------------------------------------------------
%% @author Maxim Fedorov <maximfca@gmail.com>
%%     Process Groups smoke test.
-module(spg_SUITE).
-author("maximfca@gmail.com").

%% Test server callbacks
-export([
    suite/0,
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    stop_proc/1
]).

%% Test cases exports
-export([
    app/0, app/1,
    spg/0, spg/1,
    errors/0, errors/1,
    leave_exit_race/0, leave_exit_race/1,
    single/0, single/1,
    dyn_distribution/0, dyn_distribution/1,
    process_owner_check/0, process_owner_check/1,
    overlay_missing/0, overlay_missing/1,
    two/1,
    empty_group_by_remote_leave/0, empty_group_by_remote_leave/1,
    thundering_herd/0, thundering_herd/1,
    initial/1,
    netsplit/1,
    trisplit/1,
    foursplit/1,
    exchange/1,
    nolocal/1,
    double/1,
    scope_restart/1,
    missing_scope_join/1,
    disconnected_start/1,
    forced_sync/0, forced_sync/1,
    group_leave/1
]).

-export([
    control/1,
    controller/3
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    case erlang:is_alive() of
        false ->
            %% verify epmd running (otherwise next call fails)
            (erl_epmd:names() =:= {error, address}) andalso
                begin ([] = os:cmd("epmd -daemon")),
                timer:sleep(500) %% this is needed to let some time for daemon to actually start
            end,
            %% verify that epmd indeed started
            {ok, _} = erl_epmd:names(),
            %% start a random node name
            NodeName = list_to_atom(lists:concat([atom_to_list(?MODULE), "_", os:getpid()])),
            {ok, Pid} = net_kernel:start([NodeName, shortnames]),
            [{distribution, Pid} | Config];
        true ->
            Config
    end.

end_per_suite(Config) ->
    is_pid(proplists:get_value(distribution, Config)) andalso net_kernel:stop().

init_per_testcase(app, Config) ->
    Config;
init_per_testcase(TestCase, Config) ->
    {ok, _Pid} = spg:start_link(TestCase),
    Config.

end_per_testcase(app, _Config) ->
    application:stop(spg),
    ok;
end_per_testcase(TestCase, _Config) ->
    gen_server:stop(TestCase),
    ok.

all() ->
    [app, dyn_distribution, {group, basic}, {group, cluster}, {group, performance}].

groups() ->
    [
        {basic, [parallel], [errors, spg, leave_exit_race, single, process_owner_check, overlay_missing]},
        {performance, [sequential], [thundering_herd]},
        {cluster, [parallel], [two, initial, netsplit, trisplit, foursplit,
            exchange, nolocal, double, scope_restart, missing_scope_join, empty_group_by_remote_leave,
            disconnected_start, forced_sync, group_leave]}
    ].

%%--------------------------------------------------------------------
%% TEST CASES

spg() ->
    [{doc, "This test must be names spg, to stay inline with default scope"}].

spg(_Config) ->
    ?assertNotEqual(undefined, whereis(?FUNCTION_NAME)), %% ensure scope was started
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, self())),
    ?assertEqual([self()], spg:get_local_members(?FUNCTION_NAME)),
    ?assertEqual([?FUNCTION_NAME], spg:which_groups()),
    ?assertEqual([?FUNCTION_NAME], spg:which_local_groups()),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, self())),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME)),
    ?assertEqual([], spg:which_groups(?FUNCTION_NAME)),
    ?assertEqual([], spg:which_local_groups(?FUNCTION_NAME)).

errors() ->
    [{doc, "Tests that errors are handled as expected, for example spg server crashes when it needs to"}].

errors(_Config) ->
    %% kill with 'info' and 'cast'
    ?assertException(error, badarg, spg:handle_info(garbage, garbage)),
    ?assertException(error, badarg, spg:handle_cast(garbage, garbage)),
    %% kill with call
    {ok, _Pid} = spg:start(second),
    ?assertException(exit, {{badarg, _}, _}, gen_server:call(second, garbage, 100)).

app() ->
    [{doc, "Tests application start/stop functioning, supervision & scopes"}].

app(_Config) ->
    {ok, Apps} = application:ensure_all_started(spg),
    ?assertNotEqual(undefined, whereis(spg)),
    ?assertNotEqual(undefined, ets:whereis(spg)),
    ok = application:stop(spg),
    ?assertEqual(undefined, whereis(spg)),
    ?assertEqual(undefined, ets:whereis(spg)),
    %
    application:set_env(spg, scopes, [?FUNCTION_NAME, two]),
    {ok, Apps} = application:ensure_all_started(spg),
    ?assertNotEqual(undefined, whereis(?FUNCTION_NAME)),
    ?assertNotEqual(undefined, whereis(two)),
    ?assertNotEqual(undefined, ets:whereis(?FUNCTION_NAME)),
    ?assertNotEqual(undefined, ets:whereis(two)),
    application:stop(spg),
    ?assertEqual(undefined, whereis(?FUNCTION_NAME)),
    ?assertEqual(undefined, whereis(two)).

leave_exit_race() ->
    [{doc, "Tests that spg correctly handles situation when leave and 'DOWN' messages are both in spg queue"}].

leave_exit_race(Config) when is_list(Config) ->
    process_flag(priority, high),
    [
        begin
            Pid = spawn(fun () -> ok end),
            spg:join(leave_exit_race, test, Pid),
            spg:leave(leave_exit_race, test, Pid)
        end
        || _ <- lists:seq(1, 100)].

single() ->
    [{doc, "Tests single node groups"}, {timetrap, {seconds, 5}}].

single(Config) when is_list(Config) ->
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [self(), self()])),
    ?assertEqual([self(), self(), self()], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual([self(), self(), self()], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual(not_joined, spg:leave(?FUNCTION_NAME, '$missing$', self())),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, ?FUNCTION_NAME, [self(), self()])),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    ?assertEqual([], spg:which_groups(?FUNCTION_NAME)),
    ?assertEqual([], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    %% double
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, Pid)),
    Expected = lists:sort([Pid, self()]),
    ?assertEqual(Expected, lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    ?assertEqual(Expected, lists:sort(spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    stop_proc(Pid),
    sync(?FUNCTION_NAME),
    ?assertEqual([self()], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    ok.

dyn_distribution() ->
    [{doc, "Tests that local node when distribution is started dynamically is not treated as remote node"}].

dyn_distribution(Config) when is_list(Config) ->
    OldNode = node(),
    ok = net_kernel:stop(),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    {ok, _Pid} = net_kernel:start([OldNode, shortnames]),
    ?assertEqual([self()], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)).

process_owner_check() ->
    [{doc, "Tests that process owner is local node"}].

process_owner_check(Config) when is_list(Config) ->
    {TwoPeer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    %% spawn remote process
    LocalPid = erlang:spawn(forever()),
    RemotePid = erlang:spawn(TwoPeer, forever()),
    %% check they can't be joined locally
    ?assertException(error, {nolocal, _}, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid)),
    ?assertException(error, {nolocal, _}, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [RemotePid, RemotePid])),
    ?assertException(error, {nolocal, _}, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [LocalPid, RemotePid])),
    %% check that non-pid also triggers error
    ?assertException(error, function_clause, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, undefined)),
    ?assertException(error, {nolocal, _}, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [undefined])),
    %% stop the peer
    stop_node(TwoPeer, Socket),
    ok.

overlay_missing() ->
    [{doc, "Tests that scope process that is not a part of overlay network does not change state"}].

overlay_missing(_Config) ->
    {TwoPeer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    %% join self (sanity check)
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, group, self())),
    %% remember pid from remote
    SpgPid = rpc:call(TwoPeer, erlang, whereis, [?FUNCTION_NAME]),
    RemotePid = erlang:spawn(TwoPeer, forever()),
    %% stop remote scope
    gen_server:stop(SpgPid),
    %% craft white-box request: ensure it's rejected
    ?FUNCTION_NAME ! {join, SpgPid, group, RemotePid},
    %% rejected!
    ?assertEqual([self()], spg:get_members(?FUNCTION_NAME, group)),
    %% ... reject leave too
    ?FUNCTION_NAME ! {leave, SpgPid, RemotePid, [group]},
    ?assertEqual([self()], spg:get_members(?FUNCTION_NAME, group)),
    %% join many times on remote
    %RemotePids = [erlang:spawn(TwoPeer, forever()) || _ <- lists:seq(1, 1024)],
    %?assertEqual(ok, rpc:call(TwoPeer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pid2])),
    %% check they can't be joined locally
    %?assertException(error, {nolocal, _}, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid)),
    %?assertException(error, {nolocal, _}, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [RemotePid, RemotePid])),
    %?assertException(error, {nolocal, _}, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [LocalPid, RemotePid])),
    %% check that non-pid also triggers error
    %?assertException(error, function_clause, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, undefined)),
    %?assertException(error, {nolocal, _}, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [undefined])),
    %% stop the peer
    stop_node(TwoPeer, Socket).

two(Config) when is_list(Config) ->
    {TwoPeer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, Pid)),
    ?assertEqual([Pid], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    %% first RPC must be serialised
    sync({?FUNCTION_NAME, TwoPeer}),
    ?assertEqual([Pid], rpc:call(TwoPeer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    ?assertEqual([], rpc:call(TwoPeer, spg, get_local_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    stop_proc(Pid),
    %% again, must be serialised
    sync(?FUNCTION_NAME),
    ?assertEqual([], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual([], rpc:call(TwoPeer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),

    Pid2 = erlang:spawn(TwoPeer, forever()),
    Pid3 = erlang:spawn(TwoPeer, forever()),
    ?assertEqual(ok, rpc:call(TwoPeer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pid2])),
    ?assertEqual(ok, rpc:call(TwoPeer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pid3])),
    %% serialise through the *other* node
    sync({?FUNCTION_NAME, TwoPeer}),
    ?assertEqual(lists:sort([Pid2, Pid3]),
        lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    %% stop the peer
    stop_node(TwoPeer, Socket),
    %% hope that 'nodedown' comes before we route our request
    sync(?FUNCTION_NAME),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ok.

empty_group_by_remote_leave() ->
    [{doc, "Empty group should be deleted from nodes."}].

empty_group_by_remote_leave(Config) when is_list(Config) ->
    {TwoPeer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    RemoteNode = rpc:call(TwoPeer, erlang, whereis, [?FUNCTION_NAME]),
    RemotePid = erlang:spawn(TwoPeer, forever()),
    % remote join
    ?assertEqual(ok, rpc:call(TwoPeer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    sync({?FUNCTION_NAME, TwoPeer}),
    ?assertEqual([RemotePid], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    % inspecting internal state is not best practice, but there's no other way to check if the state is correct.
    {state, _, _, #{RemoteNode := {_, RemoteMap}}} = sys:get_state(?FUNCTION_NAME),
    ?assertEqual(#{?FUNCTION_NAME => [RemotePid]}, RemoteMap),
    % remote leave
    ?assertEqual(ok, rpc:call(TwoPeer, spg, leave, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    sync({?FUNCTION_NAME, TwoPeer}),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
        {state, _, _, #{RemoteNode := {_, NewRemoteMap}}} = sys:get_state(?FUNCTION_NAME),
    % empty group should be deleted.
    ?assertEqual(#{}, NewRemoteMap),

    %% another variant of emptying a group remotely: join([Pi1, Pid2]) and leave ([Pid2, Pid1])
    RemotePid2 = erlang:spawn(TwoPeer, forever()),
    ?assertEqual(ok, rpc:call(TwoPeer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, [RemotePid, RemotePid2]])),
    sync({?FUNCTION_NAME, TwoPeer}),
    ?assertEqual([RemotePid, RemotePid2], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    %% now leave
    ?assertEqual(ok, rpc:call(TwoPeer, spg, leave, [?FUNCTION_NAME, ?FUNCTION_NAME, [RemotePid2, RemotePid]])),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    {state, _, _, #{RemoteNode := {_, NewRemoteMap}}} = sys:get_state(?FUNCTION_NAME),
    stop_node(TwoPeer, Socket),
    ok.

thundering_herd() ->
    [{doc, "Thousands of overlay network nodes sending sync to us, and we time out!"}, {timetrap, {seconds, 5}}].

thundering_herd(Config) when is_list(Config) ->
    GroupCount = 10000,
    SyncCount = 2000,
    %% make up a large amount of groups
    [spg:join(?FUNCTION_NAME, {group, Seq}, self()) || Seq <- lists:seq(1, GroupCount)],
    %% initiate a few syncs - and those are really slow...
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    PeerPid = erlang:spawn(Peer, forever()),
    PeerPg = rpc:call(Peer, erlang, whereis, [?FUNCTION_NAME], 1000),
    %% WARNING: code below acts for white-box! %% WARNING
    FakeSync = [{{group, 1}, [PeerPid, PeerPid]}],
    [gen_server:cast(?FUNCTION_NAME, {sync, PeerPg, FakeSync}) || _ <- lists:seq(1, SyncCount)],
    %% next call must not timetrap, otherwise test fails
    spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, self()),
    stop_node(Peer, Socket).

initial(Config) when is_list(Config) ->
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, Pid)),
    ?assertEqual([Pid], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    %% first RPC must be serialised
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual([Pid], rpc:call(Peer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),

    ?assertEqual([], rpc:call(Peer, spg, get_local_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    stop_proc(Pid),
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual([], rpc:call(Peer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    stop_node(Peer, Socket),
    ok.

netsplit(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    ?assertEqual(Peer, rpc(Socket, erlang, node, [])), %% just to test RPC
    RemoteOldPid = erlang:spawn(Peer, forever()),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, '$invisible', RemoteOldPid])),
    %% hohoho, partition!
    net_kernel:disconnect(Peer),
    ?assertEqual(Peer, rpc(Socket, erlang, node, [])), %% just to ensure RPC still works
    RemotePid = rpc(Socket, erlang, spawn, [forever()]),
    ?assertEqual([], rpc(Socket, erlang, nodes, [])),
    ?assertEqual(ok, rpc(Socket, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])), %% join - in a partition!

    ?assertEqual(ok, rpc(Socket, spg, leave, [?FUNCTION_NAME, '$invisible', RemoteOldPid])),
    ?assertEqual(ok, rpc(Socket, spg, join, [?FUNCTION_NAME, '$visible', RemoteOldPid])),
    ?assertEqual([RemoteOldPid], rpc(Socket, spg, get_local_members, [?FUNCTION_NAME, '$visible'])),
    %% join locally too
    LocalPid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, LocalPid)),

    ?assertNot(lists:member(Peer, nodes())), %% should be no nodes in the cluster

    pong = net_adm:ping(Peer),
    %% now ensure sync happened
    Pids = lists:sort([RemotePid, LocalPid]),
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual(Pids, lists:sort(rpc:call(Peer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME]))),
    ?assertEqual([RemoteOldPid], spg:get_members(?FUNCTION_NAME, '$visible')),
    stop_node(Peer, Socket),
    ok.

trisplit(Config) when is_list(Config) ->
    {Peer, Socket1} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    _PeerPid1 = erlang:spawn(Peer, forever()),
    PeerPid2 = erlang:spawn(Peer, forever()),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, three, PeerPid2])),
    net_kernel:disconnect(Peer),
    ?assertEqual(true, net_kernel:connect_node(Peer)),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, one, PeerPid2])),
    %% now ensure sync happened
    {Peer2, Socket2} = spawn_node(?FUNCTION_NAME, trisplit_second),
    ?assertEqual(true, rpc:call(Peer2, net_kernel, connect_node, [Peer])),
    ?assertEqual(lists:sort([node(), Peer]), lists:sort(rpc:call(Peer2, erlang, nodes, []))),
    sync({?FUNCTION_NAME, Peer2}),
    ?assertEqual([PeerPid2], rpc:call(Peer2, spg, get_members, [?FUNCTION_NAME, one])),
    stop_node(Peer, Socket1),
    stop_node(Peer2, Socket2),
    ok.

foursplit(Config) when is_list(Config) ->
    Pid = erlang:spawn(forever()),
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, one, Pid)),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, two, Pid)),
    PeerPid1 = spawn(Peer, forever()),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, one, Pid)),
    ?assertEqual(not_joined, spg:leave(?FUNCTION_NAME, three, Pid)),
    net_kernel:disconnect(Peer),
    ?assertEqual(ok, rpc(Socket, ?MODULE, stop_proc, [PeerPid1])),
    ?assertEqual(not_joined, spg:leave(?FUNCTION_NAME, three, Pid)),
    ?assertEqual(true, net_kernel:connect_node(Peer)),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, one)),
    ?assertEqual([], rpc(Socket, spg, get_members, [?FUNCTION_NAME, one])),
    stop_node(Peer, Socket),
    ok.

exchange(Config) when is_list(Config) ->
    {Peer1, Socket1} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    {Peer2, Socket2} = spawn_node(?FUNCTION_NAME, exchange_second),
    Pids10 = [rpc(Socket1, erlang, spawn, [forever()]) || _ <- lists:seq(1, 10)],
    Pids2 = [rpc(Socket2, erlang, spawn, [forever()]) || _ <- lists:seq(1, 10)],
    Pids11 = [rpc(Socket1, erlang, spawn, [forever()]) || _ <- lists:seq(1, 10)],
    %% kill first 3 pids from node1
    {PidsToKill, Pids1} = lists:split(3, Pids10),

    ?assertEqual(ok, rpc(Socket1, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pids10])),
    sync({?FUNCTION_NAME, Peer1}),
    ?assertEqual(lists:sort(Pids10), lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    [rpc(Socket1, ?MODULE, stop_proc, [Pid]) || Pid <- PidsToKill],
    sync(?FUNCTION_NAME),
    sync({?FUNCTION_NAME, Peer1}),

    Pids = lists:sort(Pids1 ++ Pids2 ++ Pids11),
    ?assert(lists:all(fun erlang:is_pid/1, Pids)),

    net_kernel:disconnect(Peer1),
    net_kernel:disconnect(Peer2),

    sync(?FUNCTION_NAME),
    ?assertEqual([], lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),

    [?assertEqual(ok, rpc(Socket2, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pid])) || Pid <- Pids2],
    [?assertEqual(ok, rpc(Socket1, spg, join, [?FUNCTION_NAME, second, Pid])) || Pid <- Pids11],
    ?assertEqual(ok, rpc(Socket1, spg, join, [?FUNCTION_NAME, third, Pids11])),
    %% rejoin
    ?assertEqual(true, net_kernel:connect_node(Peer1)),
    ?assertEqual(true, net_kernel:connect_node(Peer2)),
    %% need to sleep longer to ensure both nodes made the exchange
    sync(?FUNCTION_NAME),
    sync({?FUNCTION_NAME, Peer1}),
    sync({?FUNCTION_NAME, Peer2}),
    ?assertEqual(Pids, lists:sort(spg:get_members(?FUNCTION_NAME, second) ++ spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    ?assertEqual(lists:sort(Pids11), lists:sort(spg:get_members(?FUNCTION_NAME, third))),

    {Left, Stay} = lists:split(3, Pids11),
    ?assertEqual(ok, rpc(Socket1, spg, leave, [?FUNCTION_NAME, third, Left])),
    sync({?FUNCTION_NAME, Peer1}),
    sync(?FUNCTION_NAME),
    ?assertEqual(lists:sort(Stay), lists:sort(spg:get_members(?FUNCTION_NAME, third))),
    ?assertEqual(not_joined, rpc(Socket1, spg, leave, [?FUNCTION_NAME, left, Stay])),
    ?assertEqual(ok, rpc(Socket1, spg, leave, [?FUNCTION_NAME, third, Stay])),
    sync({?FUNCTION_NAME, Peer1}),
    sync(?FUNCTION_NAME),
    ?assertEqual([], lists:sort(spg:get_members(?FUNCTION_NAME, third))),
    sync({?FUNCTION_NAME, Peer1}),
    sync(?FUNCTION_NAME),

    stop_node(Peer1, Socket1),
    stop_node(Peer2, Socket2),
    ok.

nolocal(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    RemotePid = spawn(Peer, forever()),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    ?assertEqual([], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    stop_node(Peer, Socket),
    ok.

double(Config) when is_list(Config) ->
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, Pid)),
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [Pid])),
    ?assertEqual([Pid, Pid], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    sync(?FUNCTION_NAME),
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual([Pid, Pid], rpc:call(Peer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    stop_node(Peer, Socket),
    ok.

scope_restart(Config) when is_list(Config) ->
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [Pid, Pid])),
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    RemotePid = spawn(Peer, forever()),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual(lists:sort([RemotePid, Pid, Pid]), lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    %% stop scope locally, and restart
    gen_server:stop(?FUNCTION_NAME),
    spg:start(?FUNCTION_NAME),
    %% ensure remote pids joined, local are missing
    sync(?FUNCTION_NAME),
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual([RemotePid], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    stop_node(Peer, Socket),
    ok.

missing_scope_join(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    ?assertEqual(ok, rpc:call(Peer, gen_server, stop, [?FUNCTION_NAME])),
    RemotePid = spawn(Peer, forever()),
    ?assertMatch({badrpc, {'EXIT', {noproc, _}}}, rpc:call(Peer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    ?assertMatch({badrpc, {'EXIT', {noproc, _}}}, rpc:call(Peer, spg, leave, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    stop_node(Peer, Socket),
    ok.

disconnected_start(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    net_kernel:disconnect(Peer),
    ?assertEqual(ok, rpc(Socket, gen_server, stop, [?FUNCTION_NAME])),
    ?assertMatch({ok, _Pid}, rpc(Socket, spg, start,[?FUNCTION_NAME])),
    ?assertEqual(ok, rpc(Socket, gen_server, stop, [?FUNCTION_NAME])),
    RemotePid = rpc(Socket, erlang, spawn, [forever()]),
    ?assert(is_pid(RemotePid)),
    stop_node(Peer, Socket),
    ok.

forced_sync() ->
    [{doc, "This test was added when lookup_element was erroneously used instead of lookup, crashing spg with badmatch, and it tests rare out-of-order sync operations"}].

forced_sync(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    Pid = erlang:spawn(forever()),
    RemotePid = spawn(Peer, forever()),
    Expected = lists:sort([Pid, RemotePid]),
    spg:join(?FUNCTION_NAME, one, Pid),

    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, one, RemotePid])),
    RemoteScopePid = rpc:call(Peer, erlang, whereis, [?FUNCTION_NAME]),
    ?assert(is_pid(RemoteScopePid)),
    %% hohoho, partition!
    net_kernel:disconnect(Peer),
    ?assertEqual(true, net_kernel:connect_node(Peer)),
    %% now ensure sync happened
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual(Expected, lists:sort(spg:get_members(?FUNCTION_NAME, one))),
    %% WARNING: this code uses spg as white-box, exploiting internals,
    %%  only to simulate broken 'sync'
    %% Fake Groups: one should disappear, one should be replaced, one stays
    %% This tests handle_sync function.
    FakeGroups = [{one, [RemotePid, RemotePid]}, {?FUNCTION_NAME, [RemotePid, RemotePid]}],
    gen_server:cast(?FUNCTION_NAME, {sync, RemoteScopePid, FakeGroups}),
    %% ensure it is broken well enough
    sync(?FUNCTION_NAME),
    ?assertEqual(lists:sort([RemotePid, RemotePid]), lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    ?assertEqual(lists:sort([RemotePid, RemotePid, Pid]), lists:sort(spg:get_members(?FUNCTION_NAME, one))),
    %% simulate force-sync via 'discover' - ask peer to send sync to us
    {?FUNCTION_NAME, Peer} ! {discover, whereis(?FUNCTION_NAME)},
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual(Expected, lists:sort(spg:get_members(?FUNCTION_NAME, one))),
    ?assertEqual([], lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    %% and simulate extra sync
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual(Expected, lists:sort(spg:get_members(?FUNCTION_NAME, one))),

    stop_node(Peer, Socket),
    ok.

group_leave(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    RemotePid = erlang:spawn(Peer, forever()),
    Total = lists:duplicate(16, RemotePid),
    {Left, Remain} = lists:split(4, Total),
    %% join 16 times!
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, two, Total])),
    ?assertEqual(ok, rpc:call(Peer, spg, leave, [?FUNCTION_NAME, two, Left])),

    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual(Remain, spg:get_members(?FUNCTION_NAME, two)),
    stop_node(Peer, Socket),
    sync(?FUNCTION_NAME),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, two)),
    ok.

%%--------------------------------------------------------------------
%% Test Helpers - start/stop additional Erlang nodes

sync(GS) ->
    _ = sys:log(GS, get).

-define (LOCALHOST, {127, 0, 0, 1}).

%% @doc Kills process Pid and waits for it to exit using monitor,
%%      and yields after (for 1 ms).
-spec stop_proc(pid()) -> ok.
stop_proc(Pid) ->
    monitor(process, Pid),
    erlang:exit(Pid, kill),
    receive
        {'DOWN', _MRef, process, Pid, _Info} ->
            timer:sleep(1)
    end.

%% @doc Executes remote call on the node via TCP socket
%%      Used when dist connection is not available, or
%%      when it's undesirable to use one.
-spec rpc(gen_tcp:socket(), module(), atom(), [term()]) -> term().
rpc(Sock, M, F, A) ->
    ok = gen_tcp:send(Sock, term_to_binary({call, M, F, A})),
    inet:setopts(Sock, [{active, once}]),
    receive
        {tcp, Sock, Data} ->
            case binary_to_term(Data) of
                {ok, Val} ->
                    Val;
                {error, Error} ->
                    {badrpc, Error}
            end;
        {tcp_closed, Sock} ->
            error(closed)
    end.

%% @doc starts peer node on this host.
%% Returns spawned node name, and a gen_tcp socket to talk to it using ?MODULE:rpc.
-spec spawn_node(Scope :: atom(), Node :: atom()) -> {node(), gen_tcp:socket()}.
spawn_node(Scope, Name) ->
    Self = self(),
    Controller = erlang:spawn(?MODULE, controller, [Name, Scope, Self]),
    receive
        {'$node_started', Node, Port} ->
            {ok, Socket} = gen_tcp:connect(?LOCALHOST, Port, [{active, false}, {mode, binary}, {packet, 4}]),
            Controller ! {socket, Socket},
            {Node, Socket};
        Other ->
            error({start_node, Name, Other})
    after 60000 ->
        error({start_node, Name, timeout})
    end.

%% @private
-spec controller(atom(), atom(), pid()) -> ok.
controller(Name, Scope, Self) ->
    Pa = filename:dirname(code:which(?MODULE)),
    Pa2 = filename:dirname(code:which(spg)),
    Args = lists:concat(["-setcookie ", erlang:get_cookie(),
            "-connect_all false -kernel dist_auto_connect never -noshell -pa ", Pa, " -pa ", Pa2]),
    {ok, Node} = test_server:start_node(Name, peer, [{args, Args}]),
    case rpc:call(Node, ?MODULE, control, [Scope], 5000) of
        {badrpc, nodedown} ->
            Self ! {badrpc, Node},
            ok;
        {Port, _PgPid} ->
            Self ! {'$node_started', Node, Port},
            controller_wait()
    end.

controller_wait() ->
    Port =
        receive
            {socket, Port0} ->
                Port0
        end,
    MRef = monitor(port, Port),
    receive
        {'DOWN', MRef, port, Port, _Info} ->
            ok
    end.

%% @doc Stops the node previously started with spawn_node,
%%      and also closes the RPC socket.
-spec stop_node(node(), gen_tcp:socket()) -> true.
stop_node(Node, Socket) when Node =/= node() ->
    true = test_server:stop_node(Node),
    Socket =/= undefined andalso gen_tcp:close(Socket),
    true.

forever() ->
    fun() -> receive after infinity -> ok end end.


-spec control(Scope :: atom()) -> {Port :: integer(), pid()}.
control(Scope) ->
    Control = self(),
    erlang:spawn(fun () -> server(Control, Scope) end),
    receive
        {port, Port, SpgPid} ->
            {Port, SpgPid};
        Other ->
            error({error, Other})
    end.

server(Control, Scope) ->
    try
        {ok, Pid} = if Scope =:= undefined -> {ok, undefined}; true -> spg:start(Scope) end,
        {ok, Listen} = gen_tcp:listen(0, [{mode, binary}, {packet, 4}, {ip, ?LOCALHOST}]),
        {ok, Port} = inet:port(Listen),
        Control ! {port, Port, Pid},
        {ok, Sock} = gen_tcp:accept(Listen),
        server_loop(Sock)
    catch
        Class:Reason:Stack ->
            Control ! {error, {Class, Reason, Stack}}
    end.

server_loop(Sock) ->
    inet:setopts(Sock, [{active, once}]),
    receive
        {tcp, Sock, Data} ->
            {call, M, F, A} = binary_to_term(Data),
            Ret =
                try
                    erlang:apply(M, F, A) of
                    Res ->
                        {ok, Res}
                catch
                    exit:Reason ->
                        {error, {'EXIT', Reason}};
                    error:Reason ->
                        {error, {'EXIT', Reason}}
                end,
            ok = gen_tcp:send(Sock, term_to_binary(Ret)),
            server_loop(Sock);
        {tcp_closed, Sock} ->
            erlang:halt(1)
    end.
