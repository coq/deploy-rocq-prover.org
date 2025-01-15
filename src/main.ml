(* Usage: github_app.exe --github-app-id APP_ID \
            --github-private-key-file=secret-key.pem \
            --github-account-allowlist ACCOUNTS \
            --github-webhook-secret-file=github-app-secret-file

   This pipeline is a GitHub app (APP_ID).
   It monitors all GitHub repositories the app is asked to handle that are
   owned by ACCOUNTS, and uses Docker to build the latest version on all
   branches and PRs. Updates to the repository list and git repositories
   are delivered as webhook events from GitHub, a suitable forwarding of
   these events to github_app.ex is required eg smee.io

*)

let program_name = "deploy-rocq-prover_org"

let build_status = "Docker image build for rocq-prover.org"

let deploy_status br =
  if br = "staging" then
    "Deployment on staging.rocq-prover.org"
  else "Deployment on rocq-prover.org"

open Current.Syntax

module Git = Current_git
module Github = Current_github
module Docker = Current_docker.Default

(* Limit to one build at a time. *)
let pool = Current.Pool.create ~label:"docker" 1

let () = Prometheus_unix.Logging.init ()

(* Link for GitHub statuses. *)
let url = Uri.of_string "http://deploy.rocq-prover.org"

let image_building = "Docker image is building"
let image_built deployment = "Docker image was built successfully" ^ (if deployment then " and deployed" else "")
let image_failed = "Docker image failed to build"

(* Map from Current.state to CheckRunStatus *)
let github_check_run_status_of_state ~deployment ?job_id = function
  | Ok _              -> Github.Api.CheckRunStatus.v ~text:(image_built deployment) ~url ?identifier:job_id (`Completed `Success) 
    ~summary:(if deployment then "Deployed" else "Built")
  | Error (`Active _) -> Github.Api.CheckRunStatus.v ~text:image_building ~url ?identifier:job_id `Queued
  | Error (`Msg m)    -> Github.Api.CheckRunStatus.v ~text:image_failed ~url ?identifier:job_id (`Completed (`Failure m)) ~summary:m

let check_run_status ~deployment x =
  let+ md = Current.Analysis.metadata x
  and+ state = Current.state x in
  match md with
  | Some { Current.Metadata.job_id; _ } -> github_check_run_status_of_state ~deployment ?job_id state
  | None -> github_check_run_status_of_state ~deployment state

module CC = Current_cache.Output(MyCompose)

let compose ?(pull=true) ~docker_context ~compose_file ~hash ~env ~name ~cwd () =
  CC.set MyCompose.{ pull } { MyCompose.Key.name; docker_context; compose_file; env; hash } 
    { MyCompose.Value.cwd }

let compose ?pull ~compose_file ~hash ~env ~name ~cwd () =
  Current.component "docker-compose@,%s@,%s" name hash |>  
  let> hash = Current.return hash in
  compose ?pull ~docker_context:None ~compose_file ~hash ~env ~name ~cwd ()

let deploy br port (doc_repo, (head, src)) = 
  let name = "rocqproverorg_www_" ^ br in
  let path = Git.Commit.repo src in
  compose ~cwd:(Fpath.to_string path) ~compose_file:"compose.yml" ~name
    ~env:[| "DOC_PATH=" ^ Fpath.to_string doc_repo; "GIT_COMMIT=" ^ Git.Commit.hash src; "LOCAL_PORT=" ^ port |]
    ~hash:(Github.Api.Commit.hash head) ()
  |> check_run_status ~deployment:true
  |> Github.Api.CheckRun.set_status (Current.return head) (deploy_status br)
  
let coq_doc_repo = Github.Repo_id.{ owner = "coq"; name = "doc" }
let rocq_prover_org_repo = Github.Repo_id.{ owner = "coq"; name = "rocq-prover.org" }
let rocq_prover_org_repo api : Github.Api.Repo.t = (api, rocq_prover_org_repo)

let get_rocq_doc_head api = 
  let doc_head = Github.Api.head_commit api coq_doc_repo in
  let local_head = Git.fetch (Current.map Github.Api.Commit.id doc_head) in
  Current.map Git.Commit.repo local_head

let pipeline ~installation () =
  let dockerfile =
    match Fpath.of_string "./Dockerfile" with
    | Ok file -> Current.return (`File file)
    | Error (`Msg s) -> failwith s
  in
  let api = Github.Installation.api installation in
  let rocq_doc_head = get_rocq_doc_head api in
  let repo = rocq_prover_org_repo api in
    Github.Api.Repo.ci_refs ~staleness:(Duration.of_day 90) (Current.return repo)
    |> Current.list_iter (module Github.Api.Commit) @@ fun head ->
    let src = Git.fetch (Current.map Github.Api.Commit.id head) in
    let headsrc = Current.pair head src in
    Current.component "Determine if deployed" |>
    let** (_doc_repo, (headc, _) as ids) = (Current.pair rocq_doc_head headsrc) in
    match Github.Api.Commit.branch_name headc with
    | Some ("main" as br) -> deploy br "8000" ids 
    | Some ("staging" as br) -> deploy br "8010" ids
    | _ -> 
      Docker.build ~pool ~pull:true ~dockerfile (`Git src)
      |> check_run_status ~deployment:false
      |> Github.Api.CheckRun.set_status head build_status

(* Access control policy. *)
let has_role user = function
  | `Viewer | `Monitor -> true
  | `Builder | `Admin -> (
      match Option.map Current_web.User.id user with
      | Some
          ( "github:mattam82" | "github:tabareau" | "github:Zimmi48"
          | "github:BastienSozeau" ) ->
          true
      | Some _ | None -> false)

let login_route github_auth =
  Routes.((s "login" /? nil) @--> Current_github.Auth.login github_auth)

let authn github_auth =
  Option.map Current_github.Auth.make_login_uri github_auth

let main config mode github_auth app =
  Lwt_main.run begin
    let installation = Github.App.installation app ~account:"coq" 59020361 in
    let engine = Current.Engine.create ~config (pipeline ~installation) in
    let webhook_secret = Current_github.App.webhook_secret app in
    (* this example does not have support for looking up job_ids for a commit *)
    let get_job_ids = (fun ~owner:_owner ~name:_name ~hash:_hash -> []) in
    let authn = authn github_auth in
    let has_role =
      if github_auth = None then Current_web.Site.allow_all
      else has_role
     in
    let routes =
      Routes.(s "webhooks" / s "github" /? nil @--> Github.webhook ~engine ~get_job_ids ~webhook_secret) ::
      login_route github_auth ::
      Current_web.routes engine
    in
    let site = Current_web.Site.(v ~has_role ?authn) ~name:program_name routes in
    Lwt.choose [
      Current.Engine.thread engine;
      Current_web.run ~mode site;
    ]
  end

(* Command-line parsing *)

open Cmdliner

let cmd =
  let doc = "Monitors rocq/rocq-prover.org and rocq/doc repositories and deploy the website." in
  let info = Cmd.info program_name ~doc in
  Cmd.v info Term.(term_result (const main $ Current.Config.cmdliner $ Current_web.cmdliner $ 
    Current_github.Auth.cmdliner $ Current_github.App.cmdliner))

let () = exit @@ Cmd.eval cmd
