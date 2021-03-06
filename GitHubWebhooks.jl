module GitHubWebhooks

#################
# import/export #
#################

import HttpCommon, HttpServer, Requests, Nettle

export WebhookTracker

#############
# Constants #
#############

# Status "Enum" #
#---------------#

immutable StatusState
    name::ASCIIString
end

const PENDING = StatusState("pending")
const ERROR = StatusState("error")
const FAILURE = StatusState("failure")
const SUCCESS = StatusState("success")

# EventKind "Enum" #
#------------------#

immutable EventKind
    header::ASCIIString
end

EventKind(request::HttpCommon.Request) = EventKind(event_header(request))

Base.(:(==))(a::EventKind, b::EventKind) = a.header == b.header

const CommitCommentEvent = EventKind("commit_comment")
const CreateEvent = EventKind("create")
const DeleteEvent = EventKind("delete")
const DeploymentEvent = EventKind("deployment")
const DeploymentStatusEvent = EventKind("deployment_status")
const DownloadEvent = EventKind("download")
const FollowEvent = EventKind("follow")
const ForkEvent = EventKind("fork")
const ForkApplyEvent = EventKind("fork_apply")
const GistEvent = EventKind("gist")
const GollumEvent = EventKind("gollum")
const IssueCommentEvent = EventKind("issue_comment")
const IssuesEvent = EventKind("issues")
const MemberEvent = EventKind("member")
const MembershipEvent = EventKind("membership")
const PageBuildEvent = EventKind("page_build")
const PublicEvent = EventKind("public")
const PullRequestEvent = EventKind("pull_request")
const PullRequestReviewCommentEvent = EventKind("pull_request_review_comment")
const PushEvent = EventKind("push")
const ReleaseEvent = EventKind("release")
const RepositoryEvent = EventKind("repository")
const StatusEvent = EventKind("status")
const TeamAddEvent = EventKind("team_add")
const WatchEvent = EventKind("watch")

# Endpoints #
#-----------#

const API_ENDPOINT = "https://api.github.com/"

###########################
# Utility Types/Functions #
###########################

function authenticate(access_token::AbstractString)
    params = Dict("access_token"=>access_token)
    response = Requests.get(API_ENDPOINT; query=params)
    if !(200 <= response.status < 300)
        error("""Attempt to authenticate with GitHub API failed.
                 Response Code: $(response.status)
                 Response Message: $(Requests.json(response))""")
    end
    return access_token
end

repo_full_name(webhook_payload) = webhook_payload["repository"]["full_name"]

has_event_header(request::HttpCommon.Request) = haskey(request.headers, "X-GitHub-Event")
event_header(request::HttpCommon.Request) = request.headers["X-GitHub-Event"]

has_sig_header(request::HttpCommon.Request) = haskey(request.headers, "X-Hub-Signature")
sig_header(request::HttpCommon.Request) = request.headers["X-Hub-Signature"]

#########
# Event #
#########

"""
An `Event` is created and fed to a `WebhookTracker`'s `handle` function whenever GitHub sends an event to the tracker.

Important functions defined on `Event` are:

- `payload`: get the event's JSON payload
- `respond`: respond to an event via GitHub's Status API
- `kind`: determine the kind of the event (e.g. `PushEvent`, `PullRequestEvent`, etc.)

You can read more about these functions by querying them in the REPL's help mode.
"""
immutable Event
    kind::EventKind
    payload::Dict
    endpoint::AbstractString
    access_token::AbstractString
end

Event(request::HttpCommon.Request, args...) = Event(EventKind(request), args...)

"""
    respond(event::Event,
            sha::AbstractString,
            state::StatusState;
            description::AbstractString="",
            context::AbstractString="default",
            target_url::AbstractString="")

Respond to the event with a status generated from the given arguments.

The `sha` argument specifies the commit associated with the status.

The `state` argument must be one of following values:

- `GitHubWebhooks.PENDING`
- `GitHubWebhooks.SUCCESS`
- `GitHubWebhooks.FAILURE`
- `GitHubWebhooks.ERROR`
"""
function respond(event::Event, sha::AbstractString, state::StatusState;
                 description::AbstractString="",
                 context::AbstractString="default",
                 target_url::AbstractString="")
    status = Dict(
        "state" => state.name,
        "target_url" => target_url,
        "description" => description,
        "context" => context
    )
    params = Dict("access_token"=>event.access_token)
    return Requests.post(event.endpoint * sha; query=params, json=status)
end

"""
    payload(event::GitHubWebhooks.Event)

Returns the JSON payload of an event as a Dict
"""
payload(event::Event) = event.payload

"""
    kind(event::Event)

Returns the `EventKind` associated with the provided `Event` (e.g. `PullRequestEvent`).
"""
kind(event::Event) = event.kind

##################
# WebhookTracker #
##################

"""
A `WebhookTracker` is a server that handles events received from GitHub Webhooks (https://developer.github.com/webhooks/). When a repository's webhook catches an event and sends it to a running `WebhookTracker`, the tracker performs some basic validation and wraps the event payload in an `Event` (use the REPL's `help` mode for more info on `GitHubWebhooks.Event`). This `Event` is then fed to the tracker's `handle` function, which defines how the tracker responds to the event.

The WebhookTracker constructor has the following signature:

    WebhookTracker(handle,
                   access_token::AbstractString,
                   secret::AbstractString,
                   user_name::AbstractString,
                   repo_name::AbstractString;
                   events::Vector{GitHubWebhooks.EventKind}=GitHubWebhooks.EventKind[],
                   secret::AbstractString="")

...where:

- `handle`: A callable object (function, type, etc.) that takes in an `Event` and returns an `HttpCommon.Response`.
- `access_token`: A GitHub access token.
- `secret`: The secret associated with the tracked webhook.
- `user_name`: The name of the user/organization under which the repository is stored.
- `repo_name`: The name of the repository on which a webhook has been activated.
- `events`: A `Vector{EventKind}` that contains all whitelisted events. **If the webhook sends an event that is not in this list, that event is ignored** and is not passed down the tracker's `handle` function.

Here's an example that demonstrates how to construct and run a `WebhookTracker` that does some really basic benchmarking on every commit and PR (the function `run_and_log_benchmarks` used below isn't actually defined, but you get the point):

    access_token = # token with repo permissions (DON'T HARDCODE THIS)
    mysecret = # webhook secret (DON'T HARDCODE THIS)

    myevents = [GitHubWebhooks.PullRequestEvent, GitHubWebhooks.PushEvent]

    tracker = WebhookTracker(access_token, mysecret,
                             "user", "repo";
                             events=myevents) do event
        payload = GitHubWebhooks.payload(event)
        kind = GitHubWebhooks.kind(event)

        if kind == GitHubWebhooks.PushEvent
            sha = payload["after"]
        elseif kind == GitHubWebhooks.PullRequestEvent
            if payload["action"] == "closed"
                return HttpCommon.Response(200)
            else
                sha = payload["pull_request"]["head"]["sha"]
            end
        end

        GitHubWebhooks.respond(event, sha, GitHubWebhooks.PENDING;
                               description="Running benchmarks...",
                               context="BenchmarkTracker")

        log = "\$(sha)-benchmarks.csv"

        print("Running and logging benchmarks to \$(log)...")
        run_and_log_benchmarks(log)
        println("done.")

        GitHubWebhooks.respond(event, sha, GitHubWebhooks.SUCCESS;
                               description="Benchmarks complete!",
                               context="BenchmarkTracker")

        return HttpCommon.Response(200)
    end

    # Start the tracker on port 8000
    GitHubWebhooks.run(tracker, 8000)

"""
immutable WebhookTracker
    server::HttpServer.Server
    function WebhookTracker(handle,
                            access_token::AbstractString,
                            secret::AbstractString,
                            user_name::AbstractString,
                            repo_name::AbstractString;
                            events::Vector{EventKind}=EventKind[])
        repo = user_name * "/" * repo_name
        status_endpoint = "$(API_ENDPOINT)repos/$(repo)/statuses/"

        authenticate(access_token)

        server = HttpServer.Server() do request, response
            try
                if !(has_secret(request, secret))
                    return HttpCommon.Response(400, "invalid signature")
                end

                if !(has_event(request, events))
                    return HttpCommon.Response(400, "invalid event")
                end

                payload = Requests.json(request)

                if !(from_repo(payload, repo))
                    return HttpCommon.Response(400, "invalid repo")
                end

                event = Event(request, payload, status_endpoint, access_token)

                return handle(event)
            catch err
                println("SERVER ERROR: $err")
                return HttpCommon.Response(500)
            end
        end

        server.http.events["listen"] = port -> begin
            println("Tracking webhook for repo $repo on $port;")
            println("Events being tracked: $events")
        end

        return new(server)
    end
end

function run(tracker::WebhookTracker, args...; kwargs...)
    return HttpServer.run(tracker.server, args...; kwargs...)
end

# Validation Functions #
#----------------------#

function has_secret(request::HttpCommon.Request, secret::AbstractString)
    payload_body = mapreduce(Char, string, request.data)
    secret_sha = "sha1="*Nettle.hexdigest("sha1", secret, payload_body)
    return has_sig_header(request) && sig_header(request) == secret_sha
end

function has_event(request::HttpCommon.Request, events::Vector{EventKind})
    return (has_event_header(request) &&
            (isempty(events) || in(EventKind(request), events)))
end

function from_repo(payload::Dict, repo::AbstractString)
    return repo_full_name(payload) == repo
end

end # module GitHubWebhooks
