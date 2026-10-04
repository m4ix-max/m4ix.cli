import Foundation

struct WorkflowStep: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: String
    var title: String
    var content: String
    var provider = "claude"
}

struct WorkflowTemplate: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var steps: [WorkflowStep]
    static let implementation = WorkflowTemplate(name: "Implement, verify, review", steps: [
        WorkflowStep(kind: "Agent", title: "Implement", content: "Implement the agreed project task. Preserve existing work and report changes."),
        WorkflowStep(kind: "Check", title: "Test", content: "Test"),
        WorkflowStep(kind: "Agent", title: "Review", content: "Review the implementation and verification results. Report defects and remaining risks. Do not edit files.", provider: "codex"),
        WorkflowStep(kind: "Decision", title: "Accept the result", content: "Review the changes and decide whether the task is complete.")
    ])
}

struct WorkflowRun: Codable, Identifiable {
    var id = UUID()
    var project: String
    var profileID: String
    var template: WorkflowTemplate
    var commands: [VerificationCommand]
    var step = 0
    var state = "Ready"
    var message = ""
    var sessionID: UUID?
    var checkID: UUID?
    var updatedAt = Date()
}

@MainActor
final class WorkflowService: ObservableObject {
    let root: URL
    @Published private(set) var runs: [WorkflowRun] = []
    @Published var error: String?
    private var writable = true
    private var file: URL { root.appendingPathComponent("production/workflow-runs.json") }

    init(root: URL) {
        self.root = root
        do {
            runs = try PrivateStore.read([WorkflowRun].self, from: file, default: [])
            for index in runs.indices where !["Complete", "Cancelled"].contains(runs[index].state) {
                runs[index].state = "Paused"
                runs[index].message = "Restored after restart. Inspect the prior session or check before retrying this step."
            }
        } catch { writable = false; self.error = error.localizedDescription }
    }

    func create(template: WorkflowTemplate, commands: [VerificationCommand], project: String, profileID: String) throws -> UUID {
        guard writable, !template.steps.isEmpty else { throw CommandError.failed(error ?? "Add at least one workflow step.") }
        let run = WorkflowRun(project: project, profileID: profileID, template: template, commands: commands)
        runs.insert(run, at: 0)
        try persist()
        return run.id
    }

    func advance(_ id: UUID, checks: VerificationService,
                 launch: (String, String, String, String) -> UUID?) async {
        guard let index = runs.firstIndex(where: { $0.id == id }),
              ["Ready", "Paused"].contains(runs[index].state) else { return }
        let run = runs[index]
        guard run.step < run.template.steps.count else { return }
        let step = run.template.steps[run.step]
        runs[index].message = ""
        switch step.kind {
        case "Agent":
            let prompt = "Workflow: \(run.template.name)\nStep: \(step.title)\n\n\(step.content)\n\nReport your result and await review. Workflow advancement is a user decision."
            if let sessionID = launch(run.project, run.profileID, step.provider, prompt) {
                runs[index].sessionID = sessionID
                runs[index].state = "Awaiting review"
                runs[index].message = "Open the agent session. Continue only after reviewing its work."
            } else { runs[index].state = "Paused"; runs[index].message = "Could not queue the agent. Check the project and account profile." }
        case "Check":
            guard let command = run.commands.first(where: { $0.id == step.content }), !command.command.isEmpty else {
                runs[index].state = "Paused"
                runs[index].message = "The \(step.content) command was not configured when this run started. Save it and start a new workflow."
                saveOrReport(); return
            }
            runs[index].state = "Running check"
            saveOrReport()
            let record = await checks.run(title: command.id, command: command.command, project: URL(fileURLWithPath: run.project))
            guard let current = runs.firstIndex(where: { $0.id == id }), runs[current].state == "Running check" else { return }
            runs[current].checkID = record?.id
            if record?.state == "Passed", record?.fingerprint != nil {
                runs[current].step += 1
                runs[current].state = runs[current].step == run.template.steps.count ? "Complete" : "Ready"
                saveOrReport()
                await advance(id, checks: checks, launch: launch)
                return
            }
            runs[current].state = "Paused"
            runs[current].message = record?.note.isEmpty == false ? record!.note : "Verification did not pass with current source evidence. Inspect its log before retrying."
        default:
            runs[index].state = "Awaiting review"
            runs[index].message = step.content
        }
        saveOrReport()
    }

    func approve(_ id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }), runs[index].state == "Awaiting review" else { return }
        runs[index].step += 1
        runs[index].sessionID = nil
        runs[index].state = runs[index].step == runs[index].template.steps.count ? "Complete" : "Ready"
        saveOrReport()
    }

    func cancel(_ id: UUID, checks: VerificationService) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        if let check = runs[index].checkID { checks.cancel(check) }
        // A running command is also identified by its project before its result is returned.
        checks.records.filter { $0.project == runs[index].project && $0.state == "Running" }.forEach { checks.cancel($0.id) }
        runs[index].state = "Cancelled"
        runs[index].message = "The workflow stopped. Any agent conversation remains available in Sessions."
        saveOrReport()
    }

    private func persist() throws {
        guard writable else { throw CommandError.failed(error ?? "Workflow storage is unavailable.") }
        try PrivateStore.write(runs, to: file)
    }
    private func saveOrReport() { do { try persist() } catch { self.error = error.localizedDescription } }
}
