(*
 * Copyright (c) 2009-2013 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2013      Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

(* repeat until End_of_file is raised *)
let repeat_until_eof fn =
  try while true do fn () done
  with End_of_file -> ()

(* Retrieve file extension , if any, or blank string otherwise *)
let get_extension ~file =
  let rec search_dot i =
    if i < 1 || file.[i] = '/' then None
    else if file.[i] = '.' then Some (String.sub file (i+1) (String.length file - i - 1))
    else search_dot (i - 1) in
  search_dot (String.length file - 1)

(* Walk directory and call walkfn on every file that matches extension ext *)
let walk_directory_tree exts walkfn root_dir =
  (* If extension list is empty then let all through, otherwise white list *)
  let filter_ext =
    match exts with
    | []   -> fun _ -> true
    | exts -> fun ext -> List.mem ext exts
  in
  (* Recursive directory walker *)
  let rec walk dir =
    let dh = Unix.opendir dir in
    repeat_until_eof (fun () ->
        match Unix.readdir dh with
        | "." |".." -> ()
        | f ->
          let n = Filename.concat dir f in
          if Sys.is_directory n then walk n
          else begin
            let traverse () =
              walkfn root_dir (String.sub n 2 (String.length n - 2))
            in
            match get_extension ~file:f with
            | None -> traverse ()
            | Some e when filter_ext e -> traverse ()
            | Some _ -> ()
          end
      );
    Unix.closedir dh in
  Unix.chdir root_dir;
  walk "."

open Arg
open Printf

let chunk_info = Hashtbl.create 1
let file_info = Hashtbl.create 1

let output_generated_by oc binary =
  let t = Unix.gettimeofday () in
  let months = [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun";
                  "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec" |] in
  let days = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |] in
  let time = Unix.gmtime t in
  let date =
    Printf.sprintf "%s, %d %s %d %02d:%02d:%02d GMT"
      days.(time.Unix.tm_wday) time.Unix.tm_mday
      months.(time.Unix.tm_mon) (time.Unix.tm_year+1900)
      time.Unix.tm_hour time.Unix.tm_min time.Unix.tm_sec in
  fprintf oc "(* Generated by: %s \n\
             \  Creation date: %s *)\n\n" binary date

(** Generate a set of MD5 hashed blocks, abort on collision *)
let scan_file root name =
  let full_name = Filename.concat root name in
  let stats = Unix.stat full_name in
  let size = stats.Unix.st_size in
  let fin = open_in full_name in
  let buf = Buffer.create size in
  Buffer.add_channel buf fin size;
  let s = Buffer.contents buf in
  close_in fin;
  let rev_chunks = ref [] in
  let calc_chunk b =
    let digest = Digest.to_hex (Digest.string b) in
    rev_chunks := digest :: !rev_chunks;
    if Hashtbl.mem chunk_info digest then begin
      let cur = Hashtbl.find chunk_info digest in
      if cur <> b then
        failwith ("MD5 hash collision in file " ^ name)
    end else
      Hashtbl.add chunk_info digest b
  in
  (* Split the file as a series of chunks, of size up to 4096 (to simulate reading sectors) *)
  let sec = 4096 in (* sector size *)
  let rec consume idx =
    if idx = size then
      () (* EOF *)
    else if idx+sec < size then begin
      calc_chunk (String.sub s idx sec);
      consume (idx+sec);
    end else begin (* final chunk, short *)
      calc_chunk (String.sub s idx (size-idx))
    end
  in
  consume 0;
  Hashtbl.add file_info name ((List.rev !rev_chunks),size)

let output_implementation oc =
  fprintf oc "module Internal = struct\n";
  Hashtbl.iter (fprintf oc "let d_%s = %S\n") chunk_info;
  fprintf oc "\n";
  fprintf oc "let file_chunks = function\n";
  Hashtbl.iter (fun name (chunks,_) ->
    fprintf oc " | \"%s\" | \"/%s\" -> Some [" (String.escaped name) (String.escaped name);
    List.iter (fprintf oc "  d_%s; ") chunks;
    fprintf oc "  ]\n";
  ) file_info;
  fprintf oc " | _ -> None\n";
  fprintf oc "\n";
  fprintf oc "let file_list = [";
  Hashtbl.iter (fun k _ ->  fprintf oc "\"%s\"; " (String.escaped k)) file_info;
  fprintf oc " ]\n";
  fprintf oc "let size = function\n";
  Hashtbl.iter (fun name (_,size) ->
      fprintf oc " |\"%s\" |\"/%s\" -> Some %dL\n" (String.escaped name) (String.escaped name) size
    ) file_info;
  fprintf oc " |_ -> None\n\n";
  fprintf oc "end\n\n"

let output_plain_skeleton_ml oc =
  output_string oc "
let file_list = Internal.file_list
let size name = Internal.size name

let read name =
  match Internal.file_chunks name with
  | None   -> None
  | Some c -> Some (String.concat \"\" c)"

let output_lwt_skeleton_ml oc =
  fprintf oc "
open Lwt

type t = unit

type error = Mirage_kv.error

let pp_error = Mirage_kv.pp_error

type 'a io = 'a Lwt.t

type page_aligned_buffer = Cstruct.t

let size () name =
  match Internal.size name with
  | None   -> return (Error (`Unknown_key name))
  | Some s -> return (Ok s)

let mem () name =
  match Internal.size name with
  | None -> return (Ok false)
  | Some _ -> return (Ok true)

let filter_blocks offset len blocks =
  List.rev (fst (List.fold_left (fun (acc, (offset, offset', len)) c ->
    let sub64 c x y = String.sub c (Int64.to_int x) (Int64.to_int y) in
    let len' = Int64.of_int @@ String.length c in
    let acc, consumed =
      if len = 0L
      then acc, 0L
      (* This is before the requested data *)
      else if (Int64.add offset len) < offset
      then acc, 0L
      (* This is after the requested data *)
      else if (Int64.add offset len) < offset'
      then acc, 0L
      (* Overlapping: we're inside the region but extend beyond it *)
      else if offset <= offset' && (Int64.add offset' len') >= (Int64.add offset len)
      then sub64 c (Int64.sub offset' offset) len :: acc, len
      (* Overlapping: we're outside the region but extend into it *)
      else if offset' <= offset
      then
        let l = Int64.(add (sub len' offset) offset') in
        sub64 c (Int64.sub offset offset') l :: acc, l
      (* We're completely inside the region *)
      else c :: acc, len' in
    let offset' = Int64.add offset' len' in
    let offset = Int64.add offset consumed in
    let len = Int64.sub len consumed in
    acc, (offset, offset', len)
  ) ([], (offset, 0L, len)) blocks))

let read () name offset len =
  match Internal.file_chunks name with
  | None   -> return (Error (`Unknown_key name))
  | Some c ->
    let bufs = List.map (fun buf ->
      let pg = Io_page.to_cstruct (Io_page.get 1) in
      let len = String.length buf in
      Cstruct.blit_from_string buf 0 pg 0 len;
      Cstruct.sub pg 0 len
    ) (filter_blocks offset len c) in
    return (Ok bufs)

let connect () = return_unit

let disconnect () = return_unit
"

let output_lwt_skeleton_mli oc =
  fprintf oc "
include Mirage_kv_lwt.RO
val connect : unit -> t Lwt.t"
