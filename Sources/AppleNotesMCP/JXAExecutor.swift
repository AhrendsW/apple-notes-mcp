import Foundation

struct AutomationEnvelope: Decodable, Sendable {
    let ok: Bool
    let data: MCPValue?
    let error: AutomationFailure?
}

struct AutomationFailure: Decodable, Sendable {
    let code: String
    let message: String
    let details: [String: String]?
}

final class JXAExecutor: @unchecked Sendable {
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
    }

    func run(operation: String, scriptBody: String, input: MCPValue) async throws -> MCPValue {
        let started = Date()
        let payload = valueToJSONString(input)
        let script = commonScriptPrefix + "\n" + scriptBody

        let output = try await Task.detached(priority: .utility) {
            try runOsaScript(script: script, stdin: payload)
        }.value

        let duration = String(Int(Date().timeIntervalSince(started) * 1000))
        logger.debug(operation, fields: ["duration_ms": duration])

        guard let data = output.data(using: .utf8) else {
            throw NotesError.typed(code: "automation_decode_failed", message: "osascript returned non-UTF8 output")
        }
        let envelope = try JSONDecoder().decode(AutomationEnvelope.self, from: data)
        if envelope.ok {
            return envelope.data ?? .object([:])
        }
        let failure = envelope.error ?? AutomationFailure(
            code: "apple_notes_automation_failed",
            message: "Apple Notes automation failed.",
            details: nil
        )
        throw NotesError.typed(
            code: failure.code,
            message: failure.message,
            details: failure.details ?? [:]
        )
    }
}

private func runOsaScript(script: String, stdin: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", script]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    if let data = stdin.data(using: .utf8) {
        inputPipe.fileHandleForWriting.write(data)
    }
    try? inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    let error = String(data: errorData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        let lower = error.lowercased()
        if lower.contains("not authorized")
            || lower.contains("not permitted")
            || lower.contains("permission")
            || lower.contains("privacy")
        {
            throw NotesError.typed(
                code: "apple_notes_permission_denied",
                message: "macOS denied automation access to Apple Notes.",
                details: ["stderr": sanitizeAutomationError(error)]
            )
        }
        throw NotesError.typed(
            code: "apple_notes_automation_failed",
            message: "Apple Notes automation failed.",
            details: ["stderr": sanitizeAutomationError(error)]
        )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func sanitizeAutomationError(_ text: String) -> String {
    let lower = text.lowercased()
    if lower.contains("not authorized")
        || lower.contains("not permitted")
        || lower.contains("permission")
        || lower.contains("privacy")
    {
        return "permission_denied"
    }
    if lower.contains("syntaxerror") {
        return "javascript_syntax_error"
    }
    if lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return ""
    }
    return "redacted_osascript_stderr"
}

private let commonScriptPrefix = #"""
ObjC.import('Foundation');

function readInput() {
  var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  var text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
  if (!text || text.length === 0) { return {}; }
  return JSON.parse(text);
}

function notesApp() {
  var app = Application('/System/Applications/Notes.app');
  app.includeStandardAdditions = true;
  return app;
}

function ok(data) {
  return JSON.stringify({ ok: true, data: data || {} });
}

function fail(code, message, details) {
  return JSON.stringify({ ok: false, error: { code: code, message: message, details: details || {} } });
}

function dateString(value) {
  try {
    if (!value) { return null; }
    if (value.toISOString) { return value.toISOString(); }
    return String(value);
  } catch (e) {
    return null;
  }
}

function valueOrNull(fn) {
  try { return fn(); } catch (e) { return null; }
}

function valueOrEmptyArray(fn) {
  try {
    var value = fn();
    if (!value) { return []; }
    var count = value.length;
    return value;
  } catch (e) {
    return [];
  }
}

function noteInfo(note, accountName, folderPath, includeBody) {
  return {
    appleNoteId: valueOrNull(function(){ return note.id(); }),
    title: valueOrNull(function(){ return note.name(); }) || '',
    accountName: accountName || null,
    folderPath: folderPath || null,
    bodyHTML: includeBody ? (valueOrNull(function(){ return note.body(); }) || '') : null,
    createdAt: dateString(valueOrNull(function(){ return note.creationDate(); })),
    updatedAt: dateString(valueOrNull(function(){ return note.modificationDate(); }))
  };
}

function folderInfo(folder, accountName, path) {
  var children = valueOrEmptyArray(function(){ return folder.folders(); });
  var notes = valueOrEmptyArray(function(){ return folder.notes(); });
  return {
    accountName: accountName,
    name: valueOrNull(function(){ return folder.name(); }) || '',
    path: path,
    childCount: children.length || 0,
    noteCount: notes.length || 0
  };
}

function warning(warnings, code, path) {
  if (warnings) {
    warnings.push({ code: code, path: path || null });
  }
}

function foldersOrEmpty(container, warnings, path) {
  try {
    var folders = container.folders();
    if (!folders) { return []; }
    var count = folders.length;
    return folders;
  } catch (e) {
    warning(warnings, e.code || 'folder_children_unavailable', path);
    return [];
  }
}

function accountByName(app, name) {
  var accounts = app.accounts();
  for (var i = 0; i < accounts.length; i++) {
    if (accounts[i].name() === name) { return accounts[i]; }
  }
  throw { code: 'account_not_found', message: 'Apple Notes account not found: ' + name };
}

function findChildFolder(container, name) {
  var folders = container.folders();
  for (var i = 0; i < folders.length; i++) {
    var childName = valueOrNull(function(){ return folders[i].name(); });
    if (childName === name) { return folders[i]; }
  }
  return null;
}

function splitPath(path) {
  if (!path) { return []; }
  return String(path).split('/').filter(function(part){ return part.length > 0; });
}

function getFolder(app, account, folderPath, createIfMissing) {
  var current = account;
  var parts = splitPath(folderPath);
  if (parts.length === 0) {
    var folders = account.folders();
    for (var i = 0; i < folders.length; i++) {
      if (folders[i].name() === 'Notes') { return { folder: folders[i], path: 'Notes', existing: true }; }
    }
    if (folders.length > 0) { return { folder: folders[0], path: folders[0].name(), existing: true }; }
    parts = ['Notes'];
  }

  var full = [];
  var created = false;
  for (var j = 0; j < parts.length; j++) {
    var child = findChildFolder(current, parts[j]);
    if (!child) {
      if (!createIfMissing) {
        throw { code: 'folder_not_found', message: 'Apple Notes folder not found: ' + parts.slice(0, j + 1).join('/') };
      }
      current.folders.push(app.Folder({ name: parts[j] }));
      child = findChildFolder(current, parts[j]);
      created = true;
    }
    current = child;
    full.push(parts[j]);
  }
  return { folder: current, path: full.join('/'), existing: !created };
}

function getFolderContainer(app, account, folderPath, createIfMissing) {
  var parts = splitPath(folderPath);
  if (parts.length === 0) {
    return { folder: account, path: '', existing: true };
  }
  return getFolder(app, account, folderPath, createIfMissing);
}

function joinFolderPath(parent, child) {
  return parent ? parent + '/' + child : child;
}

function collectFolders(container, accountName, prefix, out, warnings) {
  var folders = foldersOrEmpty(container, warnings, prefix);
  for (var i = 0; i < folders.length; i++) {
    try {
      var folder = folders[i];
      var name = valueOrNull(function(){ return folder.name(); });
      if (!name) {
        warning(warnings, 'folder_reference_unavailable', prefix);
        continue;
      }
      var folderName = String(name);
      var path = prefix ? prefix + '/' + folderName : folderName;
      out.push(folderInfo(folder, accountName, path));
      collectFolders(folder, accountName, path, out, warnings);
    } catch (e) {
      warning(warnings, e.code || 'folder_reference_unavailable', prefix);
    }
  }
}

function collectNotesFromFolder(folder, accountName, folderPath, out, includeBody, maxNotes) {
  var notes = folder.notes();
  for (var i = 0; i < notes.length; i++) {
    if (maxNotes && out.length >= maxNotes) { return; }
    out.push(noteInfo(notes[i], accountName, folderPath, includeBody));
  }
  var folders = folder.folders();
  for (var j = 0; j < folders.length; j++) {
    if (maxNotes && out.length >= maxNotes) { return; }
    var child = folders[j];
    collectNotesFromFolder(child, accountName, folderPath + '/' + child.name(), out, includeBody, maxNotes);
  }
}

function findNoteById(app, appleNoteId) {
  var accounts = app.accounts();
  for (var i = 0; i < accounts.length; i++) {
    var folders = accounts[i].folders();
    for (var j = 0; j < folders.length; j++) {
      var found = findNoteByIdInFolder(folders[j], accounts[i].name(), folders[j].name(), appleNoteId);
      if (found) { return found; }
    }
  }
  return null;
}

function findNoteByIdInFolder(folder, accountName, folderPath, appleNoteId) {
  var notes = folder.notes();
  for (var i = 0; i < notes.length; i++) {
    if (valueOrNull(function(){ return notes[i].id(); }) === appleNoteId) {
      return { note: notes[i], accountName: accountName, folderPath: folderPath };
    }
  }
  var folders = folder.folders();
  for (var j = 0; j < folders.length; j++) {
    var child = folders[j];
    var found = findNoteByIdInFolder(child, accountName, folderPath + '/' + child.name(), appleNoteId);
    if (found) { return found; }
  }
  return null;
}

function findNotesByTitle(app, title) {
  var matches = [];
  var accounts = app.accounts();
  for (var i = 0; i < accounts.length; i++) {
    var folders = accounts[i].folders();
    for (var j = 0; j < folders.length; j++) {
      collectTitleMatches(folders[j], accounts[i].name(), folders[j].name(), title, matches);
    }
  }
  return matches;
}

function collectTitleMatches(folder, accountName, folderPath, title, matches) {
  var notes = folder.notes();
  for (var i = 0; i < notes.length; i++) {
    if (notes[i].name() === title) {
      matches.push({ note: notes[i], accountName: accountName, folderPath: folderPath });
    }
  }
  var folders = folder.folders();
  for (var j = 0; j < folders.length; j++) {
    var child = folders[j];
    collectTitleMatches(child, accountName, folderPath + '/' + child.name(), title, matches);
  }
}

function run(argv) {
  var input = readInput();
  try {
"""#
