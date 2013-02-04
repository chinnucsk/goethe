%%==========================================================================
%%==========================================================================
%
%  Goethe Chat Module
%  
%    This API is used for online chat.  Messages are delivered immediately
%    and can only be sent to online users.
%         
%
%%==========================================================================
-module(goethe_chat).
-author('Tim Heys twheys@gmail.com').
-behaviour(goethe_module).

-export([start/0,start_link/0]).

% gen_server exports
-export([init/1,handle_internal/2,handle_inbound/5,handle_event/3,get_api/1,terminate/2,code_change/3]).

% Module application exports
-export([system_msg/2]).

% Module namespace - Must be an atom.
-define(NAME, chat).

% Module state
-record(state, {
}).


%%==========================================================================
%
%  module startup functions
%    Functions required for starting and stopping the application.
%    They do not need to be modified but can be if necessary.
%
%%==========================================================================
start() -> goethe_module:start(?NAME, ?MODULE, [], []).
start_link() -> goethe_module:start_link(?NAME, ?MODULE, [], []).


%%==========================================================================
%
%  init
%    Handles creation of a Module record and other necessary
%  terminate
%    Called when the application shuts down.
%  code change
%    Called when a code update occurs
%
%%==========================================================================
init(_Args) -> {ok, #state{}}.
terminate(_Reason, _State) -> normal.
code_change(_OldVsn, State, _Extra) -> {ok, State}.


%%==========================================================================
%
%  internal api
%    Public API for application functions. These functions handle calls
%    from other modules.
%
%%==========================================================================
system_msg(Target, Msg) -> goethe_module:handle_internal(?NAME, {system_msg, {Target, Msg}}).


%%==========================================================================
%
%  internal api impl
%    The implementation for the Public API in the previous section.
%
%%==========================================================================
handle_internal({system_msg, {Target, Msg}}, State) ->
    {ok, ToString} = Target:get(principle),
    To = list_to_binary(ToString),
    From = <<"System">>,
    Type = <<"system">>,
    goethe:notify('chat.deliver_msg', {Target, From, To, Type, Msg}),
    {reply, ok, State};

handle_internal(_Request, _State) -> no_match.


%%==========================================================================
%
%  inbound api
%    Public API for Inbound Messages. These functions receive incoming
%    messages directly from the client.
%
%%==========================================================================
handle_inbound(Role, chat, {[
            {<<"msg">>, Msg}
        ]}, Session, State) when auth == Role; admin == Role ->
    logger:debug("Received [~p] chat from client", [Role]),

	{ok, From} = Session:get(name),
    Result = case parse_chat_command(Role, Msg) of
		{private, {To, Body}} -> private_msg(Role, From, To, Body);
		{room, {Body}} -> room_msg(Role, From, Body);
		{region, {Body}} -> region_msg(Role, From, Body);
		{broadcast, {Body}} -> broadcast_msg(Role, From, Body);
        {ok, {Body}} -> default_msg(Role, From, Body);
        {error, msg_parse_error} -> {nack, {<<"chat.parse">>}}
	end,
    case Result of
        {Ack, Reply} -> {Ack, Reply, State};
        Ack -> {Ack, State}
    end;

handle_inbound(_Role, _Action, _Data, _Session, _State) -> no_match.


%%==========================================================================
%
%  events api
%    Public API for Events. These functions are called when the expected
%    event occurs, such as start up or user authentication.
%
%%==========================================================================
handle_event('chat.deliver_msg', {Role, Target, From, Type, Msg}, State)
    when is_binary(From), is_atom(Type), is_binary(Msg) ->
    logger:debug("Delivering chat ~p -> ~p(~p) [~p]", [From, Target, Type, Msg]),
	Target:send_msg(
        {[{<<"chat.deliver">>,
            {[
                {<<"from">>,From},
                {<<"type">>,Type},
                {<<"msg">>,Msg}
                | case Role of
                    admin -> [{<<"is_admin">>,<<"true">>}];
                    _ -> []
                  end
            ]}
        }]}
    ),
    {ok, State};

handle_event(_Event, _Data, _State) -> no_match.


%%==========================================================================
%
%  get api
%    Sends a description of the JSON API of this module available to the
%    client for the given role.
%
%%==========================================================================
get_api(_Role) -> {ok, {}}.


%%==========================================================================
%
%  util functions
%
%%==========================================================================
parse_chat_command(Role, Bin) when is_binary (Bin) ->
    parse_chat_command(Role, binary_to_list(Bin));
parse_chat_command(_, "/w " ++ Rest) when length(Rest) > 0 ->
    Pos = string:str(Rest, " "),
    if
       Pos > 1, length(Rest) > (Pos + 1) ->
            To = string:substr(Rest, 1, Pos - 1),
            Msg = string:substr(Rest, Pos+1),
            {private,
                {list_to_binary(To),
                list_to_binary(Msg)}};  
       true ->
            {error, msg_parse_error}
    end;
parse_chat_command(_, "/r " ++ Msg) when length(Msg) > 0 ->
    {room, {list_to_binary(Msg)}};  
parse_chat_command(_, Msg) ->
    {ok, {list_to_binary(Msg)}}.

private_msg(Role, From, To, Msg) ->
    case goethe:get_session_by_username(To) of
    {ok, Target} ->
        goethe:notify('chat.deliver_msg', {Role, Target, From, private, Msg}),
        {ack, [
            {<<"to">>,To},
            {<<"type">>,private},
            {<<"msg">>,Msg}]};
    {error, not_found} ->
        {nack, {<<"not_found">>, {<<"user">>, To}}}
    end.

room_msg(Role, From, Msg) ->
    goethe:notify('chat.room_chat', {Role, From, Msg}),
    ok.

region_msg(Role, From, Msg) ->
    goethe:notify('chat.region_chat', {Role, From, Msg}),
    ok.

broadcast_msg(Role, From, Msg) ->
    goethe:notify('chat.broadcast', {Role, From, Msg}),
    ok.

default_msg(Role, From, Msg) ->
    goethe:notify(default, chat, {Role, From, Msg}),
    ok.