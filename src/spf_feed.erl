%%%-------------------------------------------------------------------
%%% @author Rick Payne <rickp@rossfell.co.uk>
%%% @copyright (C) 2014, Alistair Woodman, California USA <awoodman@netdef.org>
%%% @doc
%%%
%%% spf_feed provides a feed of the output of the SPF run so we can
%%% use it to generate the graph in a webpage.
%%%
%%% This file is part of AutoISIS.
%%%
%%% License:
%%% AutoISIS can be used (at your option) under the following GPL or under
%%% a commercial license
%%% 
%%% Choice 1: GPL License
%%% AutoISIS is free software; you can redistribute it and/or modify it
%%% under the terms of the GNU General Public License as published by the
%%% Free Software Foundation; either version 2, or (at your option) any
%%% later version.
%%% 
%%% AutoISIS is distributed in the hope that it will be useful, but
%%% WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See 
%%% the GNU General Public License for more details.
%%% 
%%% You should have received a copy of the GNU General Public License
%%% along with GNU Zebra; see the file COPYING.  If not, write to the Free
%%% Software Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
%%% 02111-1307, USA.
%%% 
%%% Choice 2: Commercial License Usage
%%% Licensees holding a valid commercial AutoISIS may use this file in 
%%% accordance with the commercial license agreement provided with the 
%%% Software or, alternatively, in accordance with the terms contained in 
%%% a written agreement between you and the Copyright Holder.  For
%%% licensing terms and conditions please contact us at 
%%% licensing@netdef.org
%%%
%%% @end
%%% Created : 18 Jan 2014 by Rick Payne <rickp@rossfell.co.uk>
%%%-------------------------------------------------------------------
-module(spf_feed).

-include ("../deps/yaws/include/yaws_api.hrl").
-include ("isis_system.hrl").

-export([out/1, handle_message/1, terminate/2]).

-export([handle_call/3, handle_info/2, handle_cast/2, code_change/3]).

-record(link, {source,
	       source_name,
	       target,
	       target_name,
	       value}).

out(A) ->
  case get_upgrade_header(A#arg.headers) of
    undefined ->
	  
	  {content, "text/plain", "You are not a websocket, Go away!"};
          "websocket" ->      Opts = [
				      {keepalive,         true},
				      {keepalive_timeout, 10000},
				      {drop_on_timeout,   true}
         ],
      {websocket, spf_feed, Opts};
    Any ->
      error_logger:error_msg("Got ~p from the upgrade header!", [Any])
  end.

handle_message({text, <<"start">>}) ->
    spf_summary:subscribe(self()),
    M = generate_update(0, level_1, [], "Startup"),
    {reply, {text, list_to_binary(M)}};

handle_message({close, Status, _Reason}) ->
    {close, Status};

handle_message(Any) ->
    error_logger:error_msg("Received at spf_feed ~p ", [Any]),
    noreply.

terminate(_Reason, _State) ->
    spf_summary:unsubscribe(self()),
    ok.

 handle_info({spf_summary, {Time, level_1, SPF, Reason}}, State) ->
    Json = generate_update(Time, level_1, SPF, Reason),
    {reply, {text, list_to_binary(Json)}, State};
 handle_info({spf_summary, {_, level_2, _, _Reason}}, State) ->
    {noreply, State};


%% Gen Server functions
handle_info(Info, State) ->
    error_logger:info_msg("~p unknown info msg ~p", [self(), Info]),
    {noreply, State}.

handle_cast(Msg, State) ->
    error_logger:info_msg("~p unknown msg ~p", [self(), Msg]),
    {noreply, State}.

handle_call(Request, _From, State) ->
    error_logger:info_msg("~p unknown call ~p", [self(), Request]),
    {stop, {unknown_call, Request}, State}.

code_change(_OldVsn, Data, _Extra) ->
    {ok, Data}.

get_upgrade_header(#headers{other=L}) ->
    lists:foldl(fun({http_header,_,K0,_,V}, undefined) ->
                        K = case is_atom(K0) of
                                true ->
                                    atom_to_list(K0);
                                false ->
                                    K0
                            end,
                        case string:to_lower(K) of
                            "upgrade" ->
                                string:to_lower(V);
                            _ ->
                                undefined
                        end;
                   (_, Acc) ->
                        Acc
                end, undefined, L).

generate_update(Time, Level, SPF, Reason) ->
    %% Get ourselves an ifindex->name mapping...
    Interfaces = 
	dict:from_list(
	  lists:map(fun(#isis_interface{name = Name, ifindex = IFIndex}) -> {IFIndex, Name} end,
		    isis_system:list_interfaces())),
    SPFLinks = isis_lspdb:links(isis_lspdb:get_db(Level)),
    Links = lists:map(fun({{<<A:7/binary>>,
			   <<B:7/binary>>}, Weight}) ->
			      L = #link{source = lists:flatten(io_lib:format("~p", [A])),
					source_name = isis_system:lookup_name(A),
					target = lists:flatten(io_lib:format("~p", [B])),
					target_name = isis_system:lookup_name(B),
					value = Weight},
			      {struct, lists:zip(record_info(fields, link),
						 tl(tuple_to_list(L)))}
		      end, dict:to_list(SPFLinks)),

    SendRoute = 
	fun({#isis_address{afi = AFI, mask = Mask} = A, Source},
	    NHs, Metric, Nodes) ->
		{NHStr, IFIndex} = 
		    case lists:keyfind(AFI, 1, NHs) of
			{AFI, {NHA, NHI, _Pid}} ->
			    {isis_system:address_to_string(AFI, NHA), NHI};
			false -> {"unknown nexthop", no_ifindex}
		    end,
		AStr = isis_system:address_to_string(A),
		InterfaceStr =
		    case dict:find(IFIndex, Interfaces) of
			{ok, Value} -> Value;
			_ -> "unknown"
		    end,
		FromStr = 
		    case Source of
			undefined -> "";
			#isis_address{afi = SAFI, address = SAddress, mask = SMask} ->
			    lists:flatten(io_lib:format("~s/~b",
							[isis_system:address_to_string(#isis_address{afi = SAFI,
												     address = SAddress,
												     mask = SMask}),
							 SMask]))
		    end,
		NodesStrList = lists:map(fun(N) -> isis_system:lookup_name(N) end, Nodes),
		NodesStr = string:join(NodesStrList, ", "),
		{true, {struct, [{"afi", atom_to_list(AFI)},
				 {"address", AStr},
				 {"mask", Mask},
				 {"from", FromStr},
				 {"nexthop", NHStr},
				 {"interface", InterfaceStr},
				 {"nodepath", NodesStr}]}};
	   (_, _, _, _) -> false
	end,
    UpdateRib =
	fun({_RouteNode, _NexthopNode, NextHops, Metric,
	     Routes, Nodes}) ->
		lists:filtermap(fun(R) -> SendRoute(R, NextHops, Metric, Nodes) end,
				Routes)
	end,
    Rs = lists:map(UpdateRib, SPF),
    json2:encode({struct, [{"Time", Time}, {"links", {array, Links}}, {"rib", {array, Rs}},
			   {"Reason", Reason}]}).
