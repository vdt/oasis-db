
(** 'bundle' subcommand handler
  
    Create a self contained package

    @author Sylvain Le Gall
  *)

TYPE_CONV_PATH "ODBCLIBundle"

type pkg = 
    {
      bndl_dir:            string;
      bndl_configure_args: string list;
      bndl_build_args:     string list;
      bndl_install_args:   string list;
    } with odn 

type t = 
    {
      bndl_deps: pkg list;
      bndl_exts: [ `FindlibPackage of string * OASISVersion.comparator option
                 | `ExternalTool of string ] list;
      bndl_tgt: pkg;
    } with odn 

let build t = 
  (* Check external build dependencies *)
  List.iter 
    (fun e ->
       let f : unit -> string= 
         match e with 
           | `FindlibPackage (fndlb, version_comparator) ->
               BaseCheck.package ?version_comparator fndlb
           | `ExternalTool prog ->
               BaseCheck.prog prog
       in
       let _str: string = 
         f ()
       in 
         ())
    t.bndl_exts;

  (* Build packages in order *)
  let base_pwd = 
    Sys.getcwd ()
  in
  (* Setup the build environment *)
  let build_dir = 
    Filename.concat base_pwd "_build"
  in
  let build_bindir = 
    Filename.concat build_dir "bin"
  in
  let build_libdir = 
    Filename.concat build_dir "lib"
  in
  let build_ocamllibdir =
    Filename.concat build_libdir "ocaml"
  in
  let extra_env =
    let prepend_path nm fn =
      try 
        nm, fn^":"^(Sys.getenv nm)
      with Not_found ->
        nm, fn
    in
      List.map
        (fun (nm, pth) ->
           nm^"="^(Filename.quote pth))
        [prepend_path "OCAMLPATH" build_ocamllibdir;
         "OCAMLFIND_DESTDIR", build_ocamllibdir;
         "OCAMLFIND_LDCONF", "ignore";
         prepend_path "PATH" build_bindir;
         prepend_path "LD_LIBRARY_PATH" build_libdir]
  in
  let setup args = 
    BaseExec.run "env" (extra_env @ ["ocaml"; "setup.ml"] @ args)
  in

  let build_pkg pkg = 
    try 
      Sys.chdir pkg.bndl_dir;
      setup ("-configure" :: pkg.bndl_configure_args);
      setup ("-build" :: pkg.bndl_build_args);
      setup ("-install" :: pkg.bndl_install_args);
      Sys.chdir base_pwd
    with e ->
      Sys.chdir base_pwd;
      raise e
  in

    List.iter 
      (BaseFileUtil.mkdir_parent ignore) 
      [build_bindir; 
       build_libdir; 
       build_ocamllibdir];

    List.iter 
      (fun pkg ->
         build_pkg 
           {pkg with 
              bndl_configure_args = 
                [
                  "--prefix"; Filename.quote build_dir;
                  "--libdir"; Filename.quote build_libdir;
                  "--bindir"; Filename.quote build_bindir
                ] @ pkg.bndl_configure_args})
      t.bndl_deps;

    build_pkg t.bndl_tgt


(* END EXPORT *)

(* Backup *)
let odn_of_t' = odn_of_t

open Lwt
open SubCommand
open ODBGettext
open ODBPkgVer
open FileUtil
open ODBCLICommon
open OASISTypes
open OASISVersion

(* Restore *)
let odn_of_t = odn_of_t'

let output = ref None

let input = ref None

let main () = 
  let uncompress_and_copy ~ctxt input_fn foutput_dir = 
    let input_fd = 
      Unix.openfile input_fn [Unix.O_RDONLY] 0o644
    in
      finalize
        (fun () -> 
           ODBArchive.uncompress_tmp_dir ~ctxt 
             input_fd 
             (Filename.basename input_fn)
             (fun _ _ dn ->
                let toplevel_dir = 
                  match Sys.readdir dn with 
                    | [| dn' |] ->
                        let topdn = Filename.concat dn dn' in
                          if Sys.is_directory topdn then
                            (* the toplevel is included in the tarball,
                             * this should be the standard situation 
                             *)
                            topdn

                          else
                            dn

                    | _ ->
                        dn
                in
                  foutput_dir toplevel_dir 
                  >>= fun (output_dir, extra_data) ->
                  (* TODO: use FileUtilExt.cp, to have Lwt version? *)
                  ODBProcess.run_logged ~ctxt "cp" ["-r"; toplevel_dir; output_dir]
                  >|= fun () ->
                  (output_dir, extra_data)))
        (fun () ->
           return (Unix.close input_fd))
  in

  let input_fn = 
    match !input with 
      | Some fn -> fn
      | None -> 
          failwith 
            (s_ "Subcommand 'bundle' need an input tarball.")
  in
  let output = 
    !output
  in

  let job =
    (* Create a temporary directory *)
    FileUtilExt.with_temp_dir "oasis-db-bundle-" ""
      (fun tmpdn ->
         context_lwt ()
         >>= fun ctxt ->
         uncompress_and_copy ~ctxt:ctxt.cli_odb input_fn 
           (fun topdn ->
              let oasis_fn = Filename.concat topdn "_oasis" in
                if Sys.file_exists oasis_fn then 
                  begin
                    ODBOASIS.from_file ~ctxt:ctxt.cli_odb oasis_fn 
                    >>= fun oasis ->
                    begin
                      let ver_str   = string_of_version oasis.version in
                      let tgt_nm = Printf.sprintf "%s-%s" oasis.name ver_str in
                      let bundle_nm = Printf.sprintf "%s-bundle-%s" oasis.name ver_str in
                      let rootdn = Filename.concat tmpdn bundle_nm in
                      let pkgdn = Filename.concat rootdn tgt_nm in
                        FileUtilExt.mkdir rootdn 0o755 
                        >>= fun () ->
                        return (pkgdn, (oasis, rootdn, bundle_nm, tgt_nm))
                    end
                  end
                else
                  fail 
                    (Failure 
                       (Printf.sprintf
                          (f_ "Cannot find an '_oasis' file in tarball '%s'.")
                          input_fn)))
         >>= fun (pkgdn, (oasis, rootdn, bundle_nm, tgt_nm)) ->
         (* Gather informations about repositories *)
         Lwt_list.fold_left_s
           (fun slvr (repo, fs) ->
              ODBPkgVerSolver.add_repository 
                ~ctxt:ctxt.cli_odb 
                repo
                fs 
                slvr)
           ODBPkgVerSolver.default
           ctxt.cli_repos
         >>= fun slvr ->
         begin
           let pkg_ver_deps, exts = 
             ODBPkgVerSolver.solve slvr oasis 
           in
             Lwt_list.map_s
               (fun (pkg_ver, stor) ->
                  ODBStorage.PkgVer.with_file_in 
                    stor (`PkgVer pkg_ver) `Tarball
                    (fun chn ->
                       ODBStorage.PkgVer.filename stor (`PkgVer pkg_ver) `Tarball
                       >>= fun fn ->
                       uncompress_and_copy
                         ~ctxt:ctxt.cli_odb 
                         ((ODBStorage.fs stor)#rebase fn)
                         (fun _ ->
                            let in_bundle_nm =
                              Printf.sprintf "%s-%s" 
                                pkg_ver.pkg 
                                (string_of_version pkg_ver.ver)
                            in
                            let pkgdn = 
                              Filename.concat rootdn in_bundle_nm 
                            in
                            let pkg = 
                              {
                                bndl_dir            = in_bundle_nm;
                                bndl_configure_args = []; (* TODO: set flags *)
                                bndl_build_args     = [];
                                bndl_install_args   = [];
                              }
                            in
                              return (pkgdn, pkg))))
               pkg_ver_deps
            >|= fun lst ->
            (exts, lst)
         end
         >>= fun (exts, deps) ->
         begin
           let t =
             {
               bndl_deps = List.map snd deps;
               bndl_exts = exts;
               bndl_tgt  = 
                 {
                   bndl_dir            = tgt_nm;
                   bndl_configure_args = [];
                   bndl_build_args     = [];
                   bndl_install_args   = [];
                 }
             }
           in

           let tmpl = 
             OASISFileTemplate.template_of_mlfile 
               (Filename.concat rootdn "bundle.ml")
               []
               [
                 OASISData.oasissysbundle_ml;
                 BaseData.basesysbundle_ml;
                 ODBCLIData.sysbundle_ml;
                 "open ODBCLIBundle;;";
                 (
                   Format.fprintf Format.str_formatter
                     "@[<hv2>let bundle_default =@ %a@,@];;"
                     (ODN.pp_odn ~opened_modules:["ODBCLIBundle"])
                     (odn_of_t t);
                   Format.flush_str_formatter ()
                 );
               ]
               ["ODBCLIBundle.build bundle_default;;"]
           in
           let _t : OASISFileTemplate.file_generate_change =
             OASISFileTemplate.file_generate
               ~ctxt:(ODBContext.to_oasis ctxt.cli_odb)
               ~backup:false
               tmpl
           in
               
           (* TODO: create the toplevel build.ml *)
           let output_fn =
             match output with
               | Some fn -> 
                   fn 
               | None ->
                   bundle_nm^".tar.gz"
           in
             (* Create a tarball *)
             ODBProcess.run_logged ~ctxt:ctxt.cli_odb 
               "tar" 
               ["czf"; output_fn;
                "-C"; tmpdn;
                (Filename.basename rootdn)]
         end)
  in

    Lwt_unix.run job

let scmd = 
  {(SubCommand.make
      "bundle"
      (s_ "Create a self contained tarball")
      ODBCLIData.bundle_mkd
      main)
     with 
         scmd_specs =
           [
             "-output",
             Arg.String (fun str -> output := Some str),
             "fn Name of the generated tarball. By default name of the \
                 package with '_bundle' appended.";
           ];

         scmd_anon = 
           (fun s -> 
              if !input <> None then
                failwith 
                  (Printf.sprintf
                     (f_ "Subcommand 'bundle' accept only one tarball \
                          name, don't know what to do with '%s'")
                     s);
              input := Some s);
  }

let () = 
  SubCommand.register scmd
