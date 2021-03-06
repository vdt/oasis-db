
open ODBMessage
open ODBGettext
open ODBContext
open ODBTypes
open ODBInotify
open ODBPkgVer
open Sexplib.Conv
open Lwt

TYPE_CONV_PATH "ODBIncoming"

type t =
  {
    publink: url sexp_option;
  } with sexp 

type vt = 
  V1 of t with sexp

let upgrade ~ctxt =
  function
    | V1 t -> return t

(** Load from file *)
let from_file = 
  LwtExt.IO.sexp_load vt_of_sexp upgrade

(** Dump to file *)
let to_file =
  LwtExt.IO.sexp_dump sexp_of_vt (fun t -> V1 t)

let sexp_of_tarball fn =
  fn^".sexp"

module SetString = Set.Make(String)

let inject ~ctxt stor sexp_fn tarball_fn = 
  try 
    let user = 
      let st =
        Unix.stat tarball_fn 
      in
      let pw =
        Unix.getpwuid st.Unix.st_uid 
      in
        pw.Unix.pw_name
    in
      from_file ~ctxt sexp_fn 
      >>= fun t ->

      LwtExt.IO.with_file_content tarball_fn
      >>= fun tarball_content ->

      ODBUpload.upload_begin ~ctxt 
        stor
        (Incoming user) 
        tarball_content
        (Filename.basename tarball_fn)
        t.publink
      >>=
      ODBUpload.upload_commit ~ctxt 
      >>= fun _ ->
      return ()
  with e ->
    fail e

(** Wait to have tarball + sexp files
  *)
let wait_complete ~ctxt stor ev changed = 
  match ev with 
    | Created fn ->
        begin
          return changed
        end
    
    | Changed fn ->
        begin
          let changed = 
            SetString.add fn changed 
          in
          let changed = 
            (* Filter out non-existing file *)
            SetString.filter 
              Sys.file_exists
              changed
          in

          let sexp_fn, tarball_fn  = 
            if Filename.check_suffix fn ".sexp" then
              fn, Filename.chop_extension fn
            else
              sexp_of_tarball fn, fn
          in

          let sexp_changed =
            SetString.mem sexp_fn changed 
          in
          let tarball_changed = 
             SetString.mem tarball_fn changed 
          in

            begin
              (* Check that we have received Changed event for 
               * both tarball and sexp 
               *)
              if sexp_changed && tarball_changed then
                (* We have a winner, the upload seems complete *)
                debug ~ctxt
                  (f_ "Upload complete for file '%s'")
                  tarball_fn
                >>= fun () ->
                catch 
                  (fun () ->
                     inject ~ctxt stor sexp_fn tarball_fn)
                  (fun e ->
                     error ~ctxt 
                       (f_ "Cannot process '%s': %s")
                       tarball_fn
                       (Printexc.to_string e))
                >>= fun () ->
                FileUtilExt.rm [sexp_fn; tarball_fn]
                >>= fun _ ->
                return ()

              else
                begin
                  if not sexp_changed && not tarball_changed then
                    debug ~ctxt
                      (f_ "File '%s' and '%s' are missing or not signaled \
                           as changed.")
                      sexp_fn tarball_fn

                  else if not sexp_changed then
                    debug ~ctxt
                      (f_ "File '%s' are missing or not signaled as \
                         changed.") 
                      sexp_fn

                  else if tarball_changed then
                    debug ~ctxt
                      (f_ "File '%s' are missing or not signaled as \
                         changed") 
                      tarball_fn
                  else 
                    return ()
                end
            end
            >>= fun () ->
            return changed
        end

    | Deleted fn ->
        begin
          return (SetString.remove fn changed)
        end

(** Main loop for incoming/ watch
  *)
let start ~ctxt stor = 
  let ctxt = 
    ODBContext.sub ctxt "incoming" 
  in

  (* TODO: find a way to stop monitoring 
   * run a task in parallel...
   *)
  ODBInotify.monitor_dir ~ctxt 
    (fun iev changed ->
       wait_complete ~ctxt stor iev changed)
    ctxt.incoming_dir SetString.empty
  >>= fun changed ->
  if SetString.cardinal changed > 0 then
    info ~ctxt
      (f_ "Remaining files in the incoming directory: %s")
        (String.concat (s_ ", ")
          (List.rev_map 
            (fun fn -> 
              Printf.sprintf
                (if Sys.file_exists fn then
                  format_of_string "%s"
                else
                  "%s?")
                (Filename.basename fn))
            (SetString.elements changed)))
    else
      return ()
