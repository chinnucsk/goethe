%%==========================================================================
%
%  Game Server
%    The central component of the application.  Controls the socket
%    server and maintains application state, as well as interaction
%     between other nodes.
%         
%
%%==========================================================================
-module(goethe).
-author('Tim Heys twheys@gmail.com').
-behaviour(gen_server).

-export([start/0,start_link/0]).

% gen_server exports
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).

-export([recv/3,register_module/1,register_connection/1,release_connection/1,get_modules/0]).

% public server functions
-export([ack/2,ack/3,nack/3,nack/4,notify/1,notify/2,notify/3,get_session_by_username/1]).

% public db functions
-export([db/0,get/2,get/3,get/4,clean/1,clean/2,save/1,get_enum/1,get_enum/2]).

-record(state, {
listener,db,modules
}).

start() -> gen_server:start({local, ?MODULE}, ?MODULE, [], []).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%==========================================================================
%
%  server functions
%
%%==========================================================================
register_module(Module) when is_atom(Module) ->
    gen_server:cast(?MODULE, {register_module, {Module}}).

register_connection(Connection) when is_pid(Connection) ->
    gen_server:cast(?MODULE, {register_connection, {Connection}}).
release_connection(Connection) when is_pid(Connection) ->
    gen_server:cast(?MODULE, {release_connection, {Connection}}).

recv(_, _, []) -> ok;
recv(Role, Session, [{Module, Action, Data} | Rest]) ->
    gen_server:cast(?MODULE, {recv, {Role, {Module, Action, Data}, Session}}),
    recv(Role, Session, Rest).

notify(EventName) -> notify(EventName, {}).
notify(EventName, Data) ->
    gen_server:cast(?MODULE, {notify, {EventName, Data}}).
%FIXME need a way of handling default events (events that trigger configurable actions)
notify(default, Key, Data) ->
    case application:get_env(Key) of
    undefined -> gen_server:cast(?MODULE, {notify, {Key, Data}});
    EventName -> gen_server:cast(?MODULE, {notify, {EventName, Data}})
    end.

get_modules() ->
    gen_server:call(?MODULE, get_modules).

ack(Session, Action) ->
    gen_server:cast(?MODULE, {ack, {Session, Action, []}}).
ack(Session, Action, Info) ->
    gen_server:cast(?MODULE, {ack, {Session, Action, Info}}).
nack(Session, Action, Code) ->
    gen_server:cast(?MODULE, {nack, {Session, Action, Code, []}}).
nack(Session, Action, Code, Info) ->
    gen_server:cast(?MODULE, {nack, {Session, Action, Code, Info}}).


get(View, As) ->
    gen_server:call(?MODULE, {get, {View, [], As}}).
get(View, Key, As) when is_binary(Key)->
    gen_server:call(?MODULE, {get, {View, [{key, Key}], As}});
get(View, Criteria, As) when is_list(Criteria) ->
    gen_server:call(?MODULE, {get, {View, Criteria, As}}).
get(View, Key, Criteria, As) when is_list(Criteria) ->
    gen_server:call(?MODULE, {get, {View, [{key, Key} | Criteria], As}}).

clean(View) ->
    gen_server:call(?MODULE, {clean, {View, []}}).
clean(View, Key) ->
    gen_server:call(?MODULE, {clean, {View, [{key, Key}]}}).

save(Doc) ->
    gen_server:call(?MODULE, {save, {Doc}}).

get_enum(View) ->
    gen_server:call(?MODULE, {get_enum, {View, []}}).
get_enum(View, Key) ->
    gen_server:call(?MODULE, {get_enum, {View, [{key, Key}]}}).


get_session_by_username(UserName) ->
    get({"session", "by_username"}, UserName, goethe_session).


%%==========================================================================
%
%  database functions
%
%%==========================================================================
db() -> gen_server:call(?MODULE, db).


%%==========================================================================
%
%  gen_server functions
%
%%==========================================================================
init([]) ->
    process_flag(trap_exit, true),
    {ok, Listener} = start_socket(),
    {ok, Db} = start_db(),
    {ok, #state{listener=Listener,db=Db}}.
    
start_socket() ->
    {ok, {Port}} = application:get_env(app_port),
    logger:info("Initializing Socket Server on Port: ~p.", [Port]),
    Listener = goethe_socket:start_link(Port),
    {ok, Listener}.
start_db() ->
    {ok, {Host, Port, Prefix, Options}} = application:get_env(dbs),
    S = couchbeam:server_connection(Host, Port, Prefix, Options),
    {ok, {DbName, DbOptions}} = application:get_env(db),
    {ok, Db} = couchbeam:open_db(S, DbName, DbOptions),
    {ok, {[{<<"couchdb">>,<<"Welcome">>},{<<"version">>,Version}]}} = couchbeam:server_info(S),
	logger:info("Database connection successfully initialized! Version: ~p", [binary_to_list(Version)]),
    {ok, Db}.


handle_call(db, _From, #state{db=Db} = State) ->
    {reply, {ok, Db}, State};

handle_call({get, {View, Options, As}}, _From, #state{db=Db} = State) ->
    Reply = case couchbeam_view:fold(
        fun({[{<<"id">>,_},{<<"key">>,_},{<<"value">>,Value}]}, Acc) ->
            Entity = As:new(Value),
            [Entity|Acc]
        end, [], Db, View, Options) of
        {error, Reason} ->
            logger:debug("Check get..: ~p", [Reason]),
            {error, Reason};
        [] ->
            {error, not_found};
        [Result] ->
            {ok, Result};
        Result ->
            {ok, Result}
    end,
    {reply, Reply, State};

handle_call({clean, {View, Options}}, _From, #state{db=Db} = State) ->
    Reply = case couchbeam_view:fold(
        fun({[{<<"id">>,_},{<<"key">>,_},{<<"value">>,Value}]}, Acc) ->
            [Value|Acc]
        end, [], Db, View, Options) of
        {error, Reason} ->
            logger:debug("Check get..: ~p", [Reason]),
            {error, Reason};
        Result when is_list(Result) ->
            couchbeam:delete_docs(Db, Result),
            ok
    end,
    {reply, Reply, State};

handle_call({save, {
    {[{<<"_id">>,nil} | [{<<"_rev">>,nil} | Doc]]}
        }}, _From, #state{db=Db} = State) ->
    logger:debug("Persisting new Entity ~p", [Doc]),
	Now = timestamp(),
    Reply = case couchbeam:save_doc(Db, {
            [{<<"created">>,Now} |
            [{<<"updated">>,Now} |
            Doc
        ]]}) of
        {ok, NewId} -> {ok, NewId};
        {error, Reason} -> {error, Reason}
    end,
    {reply, Reply, State};

handle_call({save, {{Doc}}}, _From, #state{db=Db} = State) ->
    logger:debug("Persisting existing Entity ~p", [Doc]),
	Now = timestamp(),
    Reply = case couchbeam:save_doc(Db, {[
            {<<"updated">>,Now} |
            Doc
        ]}) of
        {ok, NewId} -> {ok, NewId};
        Reason -> {error, Reason}
    end,
    {reply, Reply, State};

handle_call({get_enum, {View, Options}}, _From, #state{db=Db} = State) ->
    Reply = case couchbeam_view:fold(
        fun({[{<<"id">>,_},{<<"key">>,Value},{<<"value">>,_}]}, Acc) ->
            [Value|Acc]
        end, [], Db, View, Options) of
        {error, Reason} ->
            logger:debug("Check get..: ~p", [Reason]),
            {error, Reason};
        Result when is_list(Result) ->
            {ok, Result}
    end,
    {reply, Reply, State};

handle_call(Request, _From, State) ->
    logger:info("Unexpected function call in goethe: ~p", [Request]),
    {reply, inv_call, State}.


handle_cast({recv, {ready, {Module, Action, Data}, Session}}, State) ->
    logger:debug("Action: ~p.~p:~p", [Module, Action, Data]),
    spawn(goethe_module, inbound, [Module, {Action, Data}, Session]),
    {noreply, State};

handle_cast({recv, {ConnectionStatus, {_, Action, Data}, Session}}, State) ->
    logger:debug("Preliminary Action: ~p.~p:~p", [server, Action, Data]),
    if 
        encrypt == Action, pencrypt =/= ConnectionStatus ->
            spawn(goethe_module, inbound, [server, {unauthorized, {}}, Session]);

        (register == Action orelse login == Action), fencrypt =/= ConnectionStatus ->
            spawn(goethe_module, inbound, [server, {unauthorized, {}}, Session]);
        
        true -> spawn(goethe_module, inbound, [server, {Action, Data}, Session])
    end,
    {noreply, State};

handle_cast({register_module, {Module}}, #state{modules=Modules} = State) ->
    error_logger:info_msg("Loading Module [~p].", [Module]),
    FilteredModules = lists:filter(fun(X) -> X =/= Module end, Modules), 
    error_logger:info_msg("Module [~p] successfully loaded!", [Module]),
    {noreply, State#state{modules=[Module | FilteredModules]}};
    
handle_cast({notify, {Event, Data}}, #state{modules=Modules} = State) ->
    logger:info("Event: ~p:~p", [Event, Data]),
    do_notify(Modules, Event, Data),
    {noreply, State};

handle_cast({ack, {Session, Action, Info}}, State) ->
    Session:send_msg(
        {[{<<"ack">>,
            {[
                {<<"action">>,Action} |
                Info
            ]}
        }]}
    ),
    {noreply, State};
handle_cast({nack, {Session, Action, Code, Info}}, State) ->
    Session:send_msg(
        {[{<<"nack">>,
            {
                [{<<"action">>,Action} |
                [{<<"code">>,Code} |
                Info
            ]]}
        }]}
    ),
    {noreply, State};

handle_cast(Request, State) ->
    logger:info("Unexpected function cast in goethe: ~p", [Request]),
    {noreply, State}.


handle_info(_Info, State) -> {noreply, State}.
terminate(Reason, #state{listener=Listener,db=Db,modules=Modules}) ->
    logger:info("Received shut down hook. Reason: ~p. Stopping socket server.", [Reason]),
    % Stop listening
    Listener ! stop,
    
    % Clean Sessions in DB
    try couchbeam_view:fold(
        fun({[{<<"id">>,_},{<<"key">>,_},{<<"value">>,Value}]}, Acc) ->
            [Value|Acc]
        end, Db, "session", "all", [])
    catch _ -> ignore
    end,
    
    % Notify modules of Core termnating
    do_notify(Modules, reload, {server}),
    ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.


%%==========================================================================
%
%  util functions
%
%%==========================================================================
do_notify(Modules, Event, Data) ->
    F = fun(Module) -> goethe_module:notify(Module, Event, Data) end,
    spawn(lists, foreach, [F, Modules]),
    ok.

timestamp() ->
	{{Year,Month,Day},{Hour,Min,Sec}} = calendar:local_time(),
	String = lists:flatten(io_lib:fwrite("~4..0B-~2..0B-~2..0BT~2B:~2.10.0B:~2.10.0B",
                      [Year, Month, Day, Hour, Min, Sec])),
	list_to_binary(String).
