-module(game_util).

-export([bin_to_hexstr/1,hexstr_to_bin/1]).

-export([generate_string/1,generate_hash/0]).

-export([time_interval_str/1]).

-export([unicode_clean/1]).

-export([invalid_action/1,invalid_action/2,reply_to/1,reply_to/2]).
-export([json_encode/1,json_decode/1,bind_json_to_api/1,call_api/2]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%  time helper functions
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
get_interval_str(Secs) when Secs =< 60 -> io_lib:format("~p seconds", [trunc(Secs)]);
get_interval_str(Secs) when Secs =< 3600 -> io_lib:format("~p minutes, ", [trunc(Secs / 60)]) ++ get_interval_str(Secs rem 60);
get_interval_str(Secs) when Secs =< 86400 -> io_lib:format("~p hours, ", [trunc(Secs / 3600)]) ++ get_interval_str(Secs rem 3600);
get_interval_str(Secs) -> io_lib:format("~p days, ", [trunc(Secs / (86400))]) ++ get_interval_str(Secs rem (86400)).

time_interval_str({Mega, Secs, Micro} = Time) when is_integer(Mega) and is_integer(Secs) and is_integer(Micro) ->
    Seconds = calendar:datetime_to_gregorian_seconds(calendar:now_to_local_time(Time)),
    NowSeconds = calendar:datetime_to_gregorian_seconds(calendar:now_to_local_time(now())),
    case Seconds < NowSeconds of
		false -> get_interval_str(Seconds - NowSeconds);   
		true -> "None"
	end;
time_interval_str(_) -> "Unknown".


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%  encoding helper functions
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
strip_unicode([], Cur) -> Cur;
strip_unicode([H|T], Cur) when H < 128 -> strip_unicode(T, Cur ++ [H]);
strip_unicode([_|T], Cur) -> strip_unicode(T, Cur).

unicode_clean(Str) ->
    case catch rfc4627:unicode_decode(list_to_binary(Str)) of
        {'EXIT', _Reason} -> list_to_binary(strip_unicode(Str, []));
        {'utf-8', _M} -> list_to_binary(Str);
        _ -> <<>>
    end.

generate_hash() -> bin_to_hexstr(crypto:sha(generate_string(16))).

generate_string(Size) ->
	{A1, A2, A3} = now(),
	random:seed(A1, A2, A3),
    lists:flatten(lists:foldl(fun(_X,AccIn) ->
        [random:uniform(90) + 32|AccIn] end,
        [], lists:seq(1,Size))).

bin_to_hexstr(Bin) ->
  lists:flatten([io_lib:format("~2.16.0B", [X]) ||
    X <- binary_to_list(Bin)]).

hexstr_to_bin(S) ->
  try
	hexstr_to_bin(S, [])
  catch
	_:_ -> <<>>
  end.
hexstr_to_bin([], Acc) ->
  list_to_binary(lists:reverse(Acc));
hexstr_to_bin([X,Y|T], Acc) ->
  {ok, [V], []} = io_lib:fread("~16u", [X,Y]),
  hexstr_to_bin(T, [V | Acc]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%  module api helper functions
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
invalid_action(Other) ->
  logger:warn("Received an invalid action in Core API: ~p", [Other]),
  {error, invalid_action}.
invalid_action(From, Other) ->
  logger:warn("Received an invalid action in Core API: ~p  From ~p", [Other, From]),
  reply_to(From, {error, invalid_action}),
  {error, invalid_action}.

reply_to(From) ->
  From ! {self(), void},
  ok.
reply_to(From, Msg) ->
  From ! {self(), Msg},
  ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%  socket input/output helpers
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
json_encode(Tuple) ->
    try {ok, ejson:encode(Tuple)}
    catch
      Reason -> {error, Reason}
    end.

json_decode(Bin) ->
    try {ok, ejson:decode(Bin)}
    catch
      Reason -> {error, Reason}
    end.

bind_json_to_api(
        {[{<<"action">>,
            Action
        }]}) ->
    case string:tokens(binary_to_list(Action),".") of
      [Prefix, F] -> bind_json_to_api(Prefix, F, []);
      _ -> {error, invalid_action_format}
    end;

bind_json_to_api(
        {[{Action,
            Params
        }]}) ->
    case string:tokens(binary_to_list(Action),".") of
      [Prefix, F] -> bind_json_to_api(Prefix, F, Params);
      _ -> {error, invalid_action_format}
    end;
bind_json_to_api([Msg | Rest]) ->
    {ok, Action} = bind_json_to_api(Msg),
    bind_json_to_api([Action], Rest).

bind_json_to_api(Actions, []) ->
    {ok, Actions};
bind_json_to_api(Actions, [Msg | Rest]) ->
    {ok, Action} = bind_json_to_api(Msg),
    bind_json_to_api([Action | Actions], Rest).

bind_json_to_api(Prefix, F, Params) ->
  ParsedParams = bind_params_to_api(Params),
  {ok, {list_to_atom(Prefix), list_to_atom(F), ParsedParams}}.

bind_params_to_api(Params) ->
    bind_params_to_api([], Params).
bind_params_to_api(Converted, []) ->
    Converted;
bind_params_to_api(Converted, [{[{_,Value}]} | Rest]) ->
  bind_params_to_api([Value | Converted], Rest).

call_api(Role, {Prefix, F, []}) ->
  case goethe:get_module(Prefix, Role) of
  {ok, Module} ->
    Module:handle(F);
  {error, Reason} -> goethe:send_error_code(self(), client, Reason)
  end;
call_api(Role, {Prefix, F, Params}) ->
  case goethe:get_module(Prefix, Role) of
  {ok, Module} -> 
    Module:handle(F, Params);
  {error, Reason} -> goethe:send_error_code(self(), client, Reason)
  end;
call_api(_, []) ->
  ok;
call_api(Role, [Action | Actions]) ->
  call_api(Role, Action),
  call_api(Role, Actions).