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
type event =
    WRITE_DONE
  | CAN_REFILL
  | BUFFER_OVERFLOW
  | READ_DONE of int
  | BASIC_EVENT of BasicSocket.event

and buf = {
  mutable buf : string;
  mutable pos : int;
  mutable len : int;
  mutable max_buf_size : int;
  } 
  
type 'a t

type bandwidth_controler
  
and 'a handler = 'a t -> event -> unit

val max_buffer_size : int ref

val sock: 'a t -> BasicSocket.t
val create : Unix.file_descr -> 'a handler -> ('a -> string) -> 'a t
val create_simple : Unix.file_descr -> ('a -> string) -> 'a t
val create_blocking : Unix.file_descr -> 'a handler -> ('a -> string) -> 'a t
val buf : 'a t -> buf
val set_reader : 'a t -> ('a t -> int -> unit) -> unit
val buf_used : 'a t -> int -> unit
val set_handler : 'a t -> event -> ('a t -> unit) -> unit
val set_refill : 'a t -> ('a t -> unit) -> unit
val write: 'a t -> 'a -> unit
val connect: Unix.inet_addr -> int -> 'a handler -> ('a -> string) -> 'a t
val close : 'a t -> string -> unit
val shutdown : 'a t -> string -> unit
val error: 'a t -> string
val tcp_handler: 'a t -> BasicSocket.t -> BasicSocket.event -> unit
val set_closer : 'a t -> ('a t -> string -> unit) -> unit
val nread : 'a t -> int
val set_max_write_buffer : 'a t -> int -> unit  
val can_write : 'a t -> bool  
val set_monitored : 'a t -> unit
  
val close_after_write : 'a t -> unit

val create_read_bandwidth_controler : int -> bandwidth_controler
val create_write_bandwidth_controler : int -> bandwidth_controler
val set_read_controler : 'a t -> bandwidth_controler -> unit
val set_write_controler : 'a t -> bandwidth_controler -> unit
val change_rate : bandwidth_controler -> int -> unit
  
val my_ip : 'a t -> Ip.t
  
val stats :  Buffer.t -> 'a t -> unit
val buf_size : 'a t -> int * int

val can_fill : 'a t -> bool
  