(* Copyright 2001, 2002 b8_bavard, b8_fee_carabine, INRIA *)
(*
    This file is part of mldonkey.

    mldonkey is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    mldonkey is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with mldonkey; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*)

open CommonOptions
open CommonSearch
open CommonServer
open CommonComplexOptions
open CommonFile
open BasicSocket
open TcpBufferedSocket

open CommonTypes
open CommonGlobals
open Options
open LimewireTypes
open LimewireGlobals
open LimewireOptions
open LimewireProtocol
open LimewireComplexOptions
  
module DG = CommonGlobals
module DO = CommonOptions


  
let send_query min_speed keywords xml_query =
  let module Q = Query in
  let words = String2.unsplit keywords ' ' in
  let t = QueryReq {
      Q.min_speed = 0;
      Q.keywords = words;
      Q.xml_query  = "" } in
  let p = new_packet t in
  if !!verbose_servers > 0 then begin
      Printf.printf "sending query for <%s>" words; print_newline ();
    end;
  List.iter (fun s ->
      match s.server_sock with
        None -> ()
      | Some sock -> server_send sock p
  ) !connected_servers;
  p

        
let extension_list = [
    "mp3" ; "avi" ; "jpg" ; "jpeg" ; "txt" ; "mov" ; "mpg" 
]
      
let rec remove_short list list2 =
  match list with
    [] -> List.rev list2
  | s :: list -> 
      if List.mem s extension_list then 
        remove_short list (s :: list2) else 
      
      if String.length s < 5 then (* keywords should had list be 5 bytes *)
        remove_short list list2
      else
        remove_short list (s :: list2)
        
let stem s =
  let s = String.lowercase (String.copy s) in
      for i = 0 to String.length s - 1 do
        let c = s.[i] in
        match c with
          'a'..'z' | '0' .. '9' -> ()
        | _ -> s.[i] <- ' ';
      done;
      remove_short (String2.split s ' ') []
    
let get_name_keywords file_name =
  match stem file_name with 
    [] | [_] -> 
      Printf.printf "Not enough keywords to recover %s" file_name;
      print_newline ();
      [file_name]
  | l -> l
      
let recover_files () =
  List.iter (fun file ->
      let keywords = get_name_keywords file.file_name 
      in
      ignore (send_query 0 keywords "")
  ) !current_files;
  ()
  
let recover_files_from_server sock =
  if !!verbose_servers > 0 then begin
      Printf.printf "trying to recover files from server"; print_newline ();
    end;
  List.iter (fun file ->
      if !!verbose_servers > 0 then begin
          Printf.printf "FOR FILE %s" file.file_name; print_newline ();
        end;
      let keywords = get_name_keywords file.file_name in
      let words = String2.unsplit keywords ' ' in
      if !!verbose_servers > 0 then begin
          Printf.printf "sending query for <%s>" words; print_newline ();
          end;
      let module Q = Query in
      let t = QueryReq {
          Q.min_speed = 0;
          Q.keywords = words;
          Q.xml_query  = "" } in
      let p = new_packet t in
      server_send sock p
  ) !current_files;
  ()
  
  
let redirector_to_client p sock = 
(*  Printf.printf "redirector_to_client"; print_newline (); *)
  match p.pkt_payload with
    PongReq t ->
      let module P = Pong in
(*      Printf.printf "ADDING PEER %s:%d" (Ip.to_string t.P.ip) t.P.port; *)
      Fifo.put peers_queue (t.P.ip, t.P.port);
  | _ -> ()
      
let redirector_parse_header sock header = 
(*  Printf.printf "redirector_parse_header"; print_newline ();*)
  if String2.starts_with header gnutella_ok then begin
(*      Printf.printf "GOOD HEADER FROM REDIRECTOR:waiting for pongs";*)
      server_send_new sock (
        let module P = Ping in
        PingReq (P.ComplexPing {
          P.ip = DO.client_ip (Some sock);
          P.port = !!client_port;
          P.nfiles = Int32.zero;
          P.nkb = Int32.zero;
          P.s = "none:128:false";
        }))
    end else begin
      if !!verbose_servers>10 then begin
          Printf.printf "BAD HEADER FROM REDIRECTOR: "; print_newline (); 
          BigEndian.dump header;
        end;
      close sock "bad header";
      redirector_connected := false;
      raise Not_found
    end
  
let connect_to_redirector () =
  match !redirectors_to_try with
    [] ->
      redirectors_to_try := !redirectors_ips
  | ip :: tail ->
      redirectors_to_try := tail;
(*      Printf.printf "connect to redirector"; print_newline (); *)
      try
        let sock = connect  "limewire to redirector"
            (Ip.to_inet_addr ip) 6346
            (fun sock event -> 
              match event with
                BASIC_EVENT RTIMEOUT -> 
                  close sock "timeout";
                  redirector_connected := false;
(*                  Printf.printf "TIMEOUT FROM REDIRECTOR"; print_newline ()*)
              | _ -> ()
          ) in
        TcpBufferedSocket.set_read_controler sock download_control;
        TcpBufferedSocket.set_write_controler sock upload_control;

        
        redirector_connected := true;
        set_reader sock (handler !!verbose_servers redirector_parse_header
            (gnutella_handler parse redirector_to_client)
        );
        set_closer sock (fun _ _ -> 
(*            Printf.printf "redirector disconnected"; print_newline (); *)
            redirector_connected := false);
        set_rtimeout sock 10.;
        set_lifetime (TcpBufferedSocket.sock sock) 120.;
        write_string sock "GNUTELLA CONNECT/0.4\n\n";
      with e ->
          Printf.printf "Exception in connect_to_redirector: %s"
            (Printexc.to_string e); print_newline ();
          redirector_connected := false
          
let disconnect_from_server s =
  match s.server_sock with
    None -> ()
  | Some sock ->
(*
  Printf.printf "DISCONNECT FROM SERVER %s:%d" 
        (Ip.to_string s.server_ip) s.server_port;
print_newline ();
  *)
      close sock "timeout";
      s.server_sock <- None;
      set_server_state s NotConnected;
      decr nservers;
      if List.memq s !connected_servers then begin
          connected_servers := List2.removeq s !connected_servers;
        end;
      server_remove s

let add_peers headers =
  (try
      let up = List.assoc "x-try-ultrapeers" headers in
      List.iter (fun s ->
          try
            let len = String.length s in
(*            Printf.printf "NEW ULTRAPEER %s" s; print_newline ();*)
            let pos = String.index s ':' in
            let ip = String.sub s 0 pos in
            let port = String.sub s (pos+1) (len - pos - 1) in
            let ip = Ip.of_string ip in
            let port = int_of_string port in
(*            Printf.printf "ADDING UP %s:%d" (Ip.to_string ip) port;
            print_newline ();*)
            Fifo.put ultrapeers_queue (ip,port ) ;
            while Fifo.length ultrapeers_queue > !!max_known_ultrapeers do
              ignore (Fifo.take ultrapeers_queue)
            done
          
          with _ -> ()
      ) (String2.split up ',');    
    with e -> 
        Printf.printf "add_ulta_peers : %s" (Printexc.to_string e);
        print_newline () );
  (try
      let up = List.assoc "x-try" headers in
      List.iter (fun s ->
          try
            let len = String.length s in
(*            Printf.printf "NEW PEER %s" s; print_newline (); *)
            let pos = String.index s ':' in
            let ip = String.sub s 0 pos in
            let port = String.sub s (pos+1) (len - pos - 1) in
            let ip = Ip.of_string ip in
            let port = int_of_string port in
(*            Printf.printf "ADDING PEER %s:%d" (Ip.to_string ip) port;
            print_newline ();*)
            Fifo.put peers_queue (ip,port);
            while Fifo.length peers_queue > !!max_known_peers do
              ignore (Fifo.take peers_queue)
            done
          
          with _ -> ()
      ) (String2.split up ',')    
    with _ -> ())

(*
ascii: [ G N U T E L L A / 0 . 6   2 0 0   O K(13)(10) U s e r - A g e n t :   G n u c l e u s   1 . 8 . 2 . 0(13)(10) R e m o t e - I P :   2 1 2 . 1 9 8 . 2 3 5 . 1 2 3(13)(10) X - Q u e r y - R o u t i n g :   0 . 1(13)(10) X - U l t r a p e e r :   T r u e(13)(10) X - L e a f - M a x :   4 0 0(13)(10) U p t i m e :   0 D   0 3 H   3 0 M(13)(10)(13)]
*)



let update_user t =
  let module Q = QueryReply in
  let user = new_user t.Q.guid (match t.Q.dont_connect with
        Some true ->  Indirect_location ("", t.Q.guid)
      | _ -> Known_location(t.Q.ip, t.Q.port))
  in
  user.user_speed <- t.Q.speed;
  user

let update_client t =
  let module Q = QueryReply in
  let c = new_client t.Q.guid (match t.Q.dont_connect with
        Some true ->  Indirect_location ("", t.Q.guid)
      | _ -> Known_location(t.Q.ip, t.Q.port))
  in
  
  c.client_user.user_speed <- t.Q.speed;
  c
  
let server_parse_header s sock header =
  if !!verbose_servers> 10 then  BigEndian.dump_ascii header;  
  try
  if String2.starts_with header gnutella_200_ok then begin
(*      Printf.printf "GOOD HEADER FROM ULTRAPEER";
      print_newline (); *)
        set_rtimeout sock DG.half_day;
(*        Printf.printf "SPLIT HEADER..."; print_newline ();*)
      let lines = Http_client.split_header header in
      match lines with
          [] -> raise Not_found        
        | _ :: headers ->
(*            Printf.printf "CUT HEADER"; print_newline ();*)
            let headers = Http_client.cut_headers headers in
            let agent =  List.assoc "user-agent" headers in
(*            Printf.printf "USER AGENT: %s" agent; print_newline ();*)
            if String2.starts_with agent "LimeWire" ||
              String2.starts_with agent "Gnucleus" ||
              String2.starts_with agent "BearShare"              
              then
              begin
                s.server_agent <- agent;
(*                Printf.printf "LIMEWIRE Detected"; print_newline ();*)
                add_peers headers;
                if List.assoc "x-ultrapeer" headers <> "True" then begin
(*                    Printf.printf "NOT AN ULTRAPEER ???"; print_newline (); *)
                    raise Not_found;
                  end;
                connected_servers := s :: !connected_servers;

(*                Printf.printf "******** ULTRA PEER %s:%d  *******"
                  (Ip.to_string s.server_ip) s.server_port;
                print_newline (); *)
                write_string sock "GNUTELLA/0.6 200 OK\r\n\r\n";
                set_server_state s Connected_idle;
                recover_files_from_server sock
              end
            else raise Not_found
    end else 
  if String2.starts_with header gnutella_503_shielded then begin
(*      Printf.printf "GOOD HEADER FROM SIMPLE PEER";
      print_newline ();*)
      let lines = Http_client.split_header header in
      match lines with
          [] -> raise Not_found        
        | _ :: headers ->
            let headers = Http_client.cut_headers headers in
            let agent = List.assoc "user-agent" headers in
            if String2.starts_with agent "LimeWire" ||
                String2.starts_with agent "Gnucleus" ||
              String2.starts_with agent "BearShare"              
              then
              begin
(*                Printf.printf "LIMEWIRE Detected"; print_newline ();*)
                add_peers headers;                
                raise Not_found
              end
            else raise Not_found
    end else begin
(*      Printf.printf "BAD HEADER FROM SERVER: [%s]" header; print_newline (); *)
      raise Not_found
    end
  with
  | Not_found -> 
(*      Printf.printf "DISCONNECTION"; print_newline (); *)
      disconnect_from_server s
  | e -> 
(*
      Printf.printf "DISCONNECT WITH EXCEPTION %s" (Printexc.to_string e);
print_newline ();
  *)
      disconnect_from_server s
  
let server_to_client s p sock =
(*
  Printf.printf "server_to_client"; print_newline ();
print p;
  *)
  match p.pkt_payload with
  | PingReq t ->
      if p.pkt_hops <= 3 then
        server_send sock {
          p with 
          pkt_hops = p.pkt_hops + 1;
          pkt_type = PONG;
          pkt_payload = (
            let module P = Pong in
            PongReq {
              P.ip = (DO.client_ip (Some sock));
              P.port = !!client_port;
              P.nfiles = 10;
              P.nkb = 10;
            });
        }
  | PongReq t ->
      
      let module P = Pong in
(*      Printf.printf "FROM %s:%d" (Ip.to_string t.P.ip) t.P.port; *)
      if p.pkt_uid = s.server_ping_last then begin
          s.server_nfiles_last <- s.server_nfiles_last + t.P.nfiles;
          s.server_nkb_last <- s.server_nkb_last + t.P.nkb
        end
  
  | QueryReq _ ->
(*      Printf.printf "REPLY TO QUERY NOT IMPLEMENTED YET :("; print_newline ();*)
      ()
      
  | QueryReplyReq t ->
(*      Printf.printf "REPLY TO QUERY"; print_newline ();*)
      let module Q = QueryReply in
      begin
        try
          let s = Hashtbl.find searches_by_uid p.pkt_uid in
          
          let user = update_user t in

(*          Printf.printf "ADDING RESULTS"; print_newline ();*)
          List.iter (fun f ->
(*              Printf.printf "NEW RESULT %s" f.Q.name; print_newline ();*)
              let result = new_result f.Q.name f.Q.size in
              add_source result user f.Q.index;
              
              search_add_result s.search_search result.result_result;
          ) t.Q.files
        with Not_found ->            
            Printf.printf "NO SUCH SEARCH !!!!"; print_newline (); 
            List.iter (fun ff ->
                List.iter (fun file ->
                    if file.file_name = ff.Q.name && 
                      file_size file = ff.Q.size then 
                      begin
                        Printf.printf "++++++++++++++ RECOVER FILE %s +++++++++++++" file.file_name; print_newline (); 
                        let c = update_client t in
                        add_download file c ff.Q.index;
                        end
                ) !current_files;
            ) t.Q.files
      end
  | _ -> ()

let send_pings () =
  let pl =
    let module P = Ping in
    PingReq P.SimplePing
  in
  List.iter (fun s ->
      match s.server_sock with
        None -> ()
      | Some sock -> 
          let p  = { (new_packet pl) with pkt_ttl = 1; } in
          s.server_nfiles <- s.server_nfiles_last;
          s.server_nkb <- s.server_nkb_last;
          s.server_ping_last <- p.pkt_uid;
          s.server_nfiles_last <- 0;
          s.server_nkb_last <- 0;
          server_send sock p
  ) !connected_servers
      
let connect_server (ip,port) =
  if !!verbose_servers > 5 then begin
      Printf.printf "SHOULD CONNECT TO %s:%d" (Ip.to_string ip) port;
      print_newline ();
    end;
  let s = new_server ip port in
  match s.server_sock with
    Some _ -> ()
  | None -> 
      try
        let sock = connect "limewire to server"
          (Ip.to_inet_addr ip) port
            (fun sock event -> 
              match event with
                BASIC_EVENT RTIMEOUT -> 
(*                  Printf.printf "RTIMEOUT"; print_newline (); *)
                  disconnect_from_server s
              | _ -> ()
          ) in
        TcpBufferedSocket.set_read_controler sock download_control;
        TcpBufferedSocket.set_write_controler sock upload_control;

        set_server_state s Connecting;
        s.server_sock <- Some sock;
        incr nservers;
        set_reader sock (handler !!verbose_servers (server_parse_header s)
          (gnutella_handler parse (server_to_client s))
        );
        set_closer sock (fun _ error -> 
(*            Printf.printf "CLOSER %s" error; print_newline ();*)
            disconnect_from_server s);
        set_rtimeout sock !!server_connection_timeout;
        let s = Printf.sprintf 
          "GNUTELLA CONNECT/0.6\r\nUser-Agent: LimeWire 2.4.4\r\nX-My-Address: %s:%d\r\nX-Ultrapeer: False\r\nX-Query-Routing: 0.1\r\nRemote-IP: %s\r\n\r\n"
          (Ip.to_string (DO.client_ip (Some sock))) !!client_port
            (Ip.to_string s.server_ip)
        in
(*
        Printf.printf "SENDING"; print_newline ();
        AP.dump s;
  *)
        write_string sock s;
      with _ ->
          disconnect_from_server s
          
  
let try_connect_ultrapeer () =
(*  Printf.printf "try_connect_ultrapeer"; print_newline ();*)
  let s = try
      Fifo.take ultrapeers_queue
    with _ ->
        try 
          Fifo.take peers_queue 
        with _ ->
            if not !redirector_connected then              
              connect_to_redirector ();
            raise Not_found
  in
  connect_server s;
  ()

let connect_servers () =
  (*
  Printf.printf "connect_servers %d %d" !nservers !!max_ultrapeers; 
print_newline ();
  *)
  if !nservers < !!max_ultrapeers then begin
      for i = !nservers to !!max_ultrapeers - 1 do
        try_connect_ultrapeer ()
      done
    end

let get_file_from_source c file =
  if connection_can_try c.client_connection_control then begin
      connection_try c.client_connection_control;
      match c.client_user.user_kind with
        Indirect_location ("", uid) ->
          Printf.printf "++++++ ASKING FOR PUSH +++++++++"; print_newline ();   

(* do as if connection failed. If it connects, connection will be set to OK *)
          connection_failed c.client_connection_control;
          let module P = Push in
          let t = PushReq {
              P.guid = uid;
              P.ip = DO.client_ip None;
              P.port = !!client_port;
              P.index = List.assq file c.client_downloads;
            } in
          let p = new_packet t in
          List.iter (fun s ->
              match s.server_sock with
                None -> ()
              | Some sock -> server_send sock p
          ) !connected_servers
      | _ ->
          LimewireClients.connect_client c
    end
    
let download_file (r : result) =
  let file = new_file (Md4.random ()) r.result_name r.result_size in
  Printf.printf "DOWNLOAD FILE %s" file.file_name; print_newline ();
  if not (List.memq file !current_files) then begin
      current_files := file :: !current_files;
    end;
  List.iter (fun (user, index) ->
      Printf.printf "Source %s %d" (Md4.to_string user.user_uid)
      index; print_newline ();
      let c = new_client user.user_uid user.user_kind in
      add_download file c index;
      get_file_from_source c file;
  ) r.result_sources;
  ()

let ask_for_files () =
  List.iter (fun file ->
      List.iter (fun c ->

          get_file_from_source c file
      ) file.file_clients
  ) !current_files;
  ()
  
  

  
let disconnect_server s =
      match s.server_sock with
        None -> ()
      | Some sock -> close sock "user disconnect"
    
let _ =
(*  server_ops.op_server_connect <- connect_server; *)
  server_ops.op_server_disconnect <- disconnect_server;
(*
(*  server_ops.op_server_query_users <- (fun s -> *)
      match s.server_sock with
        None -> ()
      | Some sock ->
          server_send sock (GetNickListReq)
  );
(*  server_ops.op_server_users <- (fun s -> *)
      List2.tail_map (fun u -> as_user u.user_user) s.server_users
);
  *)
  server_ops.op_server_remove <- (fun s ->
      disconnect_server s;
      server_remove s
  )
  
  