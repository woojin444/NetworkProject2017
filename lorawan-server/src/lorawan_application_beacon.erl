-module(lorawan_application_beacon).
-behaviour(lorawan_application).

-import(lorawan_mac, send_beacon).
-export([init/1, handle_join/3, handle_rx/4]).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").

init(_App) ->
    {ok, [
        {"/ws/:type/:name/raw", lorawan_ws_frames, [<<"raw">>]},
        {"/ws/:type/:name/json", lorawan_ws_frames, [<<"json">>]},
        {"/ws/:type/:name/www-form", lorawan_ws_frames, [<<"www-form">>]}
    ]}.

handle_join(_Gateway, _Device, _Link) ->
    % accept any device
    ok.

% rxdata last_lost is never used
handle_rx(_Gateway, _Link, #rxdata{last_lost=true}, _RxQ) ->
    retransmit;
% Set a Timer to send a beacon.
handle_rx(Gateway, #link{devaddr=DevAddr}=Link, #rxdata{port=Port} = RxData, RxQ) ->
    case send_to_sockets(Gateway, Link, RxData, RxQ) of
        [] -> lager:warning("Frame not sent to any process");
        _List -> ok
    end,
    % send_beacon(#link{devaddr=DevAddr}, TxQ, beacon)
    % -record(beacon, {devaddr, fcnt, fopts, fport, data})
    timer:apply_interval(50000, lorawan_mac, send_beacon, [Link, 0,
      #beacon{devaddr = DevAddr, fcnt = RxData.fcnt, fopts = 0, fport = RxData.port, <<>>}])
    lorawan_handler:send_stored_frames(DevAddr, Port).

send_to_sockets(Gateway, #link{devaddr=DevAddr, appid=AppID}=Link, RxData, RxQ) ->
    Sockets = lorawan_ws_frames:get_processes(DevAddr, AppID),
    [Pid ! {send, Gateway, Link, RxData, RxQ} || Pid <- Sockets].

% end of file
