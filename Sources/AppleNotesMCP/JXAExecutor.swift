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

function sleepSeconds(seconds) {
  $.NSThread.sleepForTimeInterval(seconds);
}

function experimentalFocusNoteForTyping(note) {
  var app = notesApp();
  app.activate();
  sleepSeconds(0.3);
  app.show(note);
  sleepSeconds(1.0);
  var events = Application('System Events');
  events.includeStandardAdditions = true;
  events.keyCode(36);
  sleepSeconds(0.4);
  events.keyCode(125, { using: ['command down'] });
  sleepSeconds(0.4);
  return events;
}

function safeUpdatedNoteInfo(note, accountName, folderPath, bodyHTML) {
  return {
    appleNoteId: valueOrNull(function(){ return note.id(); }),
    title: valueOrNull(function(){ return note.name(); }) || '',
    accountName: accountName || null,
    folderPath: folderPath || null,
    bodyHTML: bodyHTML,
    createdAt: dateString(valueOrNull(function(){ return note.creationDate(); })),
    updatedAt: dateString(valueOrNull(function(){ return note.modificationDate(); }))
  };
}

function classifiedUIError(e) {
  var text = '';
  try { text = String((e && (e.message || e.toString())) || ''); } catch (_) { text = ''; }
  var lower = text.toLowerCase();
  if (lower.indexOf('not authorized') >= 0
      || lower.indexOf('not permitted') >= 0
      || lower.indexOf('privacy') >= 0
      || lower.indexOf('assistive') >= 0
      || lower.indexOf('accessibility') >= 0) {
    return 'accessibility_or_automation_permission_denied';
  }
  if (lower.indexOf("can't get object") >= 0 || lower.indexOf('invalid index') >= 0) {
    return 'note_object_or_ui_element_unavailable';
  }
  if (lower.indexOf('system events') >= 0) {
    return 'system_events_unavailable';
  }
  if (lower.length === 0) {
    return 'unknown_ui_automation_error';
  }
  return 'redacted_ui_automation_error';
}

function experimentalAppendTextToNote(note, text) {
  var events = experimentalFocusNoteForTyping(note);
  events.keystroke(text);
  sleepSeconds(0.4);
}

function experimentalAppendNativeNoteLink(note, targetTitle, prefixText) {
  var events = experimentalFocusNoteForTyping(note);
  if (prefixText && prefixText.length > 0) {
    events.keystroke(prefixText);
    sleepSeconds(0.2);
  }
  events.keystroke('>>');
  sleepSeconds(0.5);
  events.keystroke(targetTitle);
  sleepSeconds(0.7);
  events.keyCode(36);
  sleepSeconds(0.5);
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

function updateNoteBodyById(app, appleNoteId, bodyHTML) {
  var accounts = app.accounts();
  for (var i = 0; i < accounts.length; i++) {
    var accountName = valueOrNull(function(){ return accounts[i].name(); });
    if (!accountName) { continue; }
    var folders = foldersOrEmpty(accounts[i], null, '');
    for (var j = 0; j < folders.length; j++) {
      var folderName = valueOrNull(function(){ return folders[j].name(); });
      if (!folderName) { continue; }
      var updated = updateNoteBodyByIdInFolder(folders[j], String(accountName), String(folderName), appleNoteId, bodyHTML);
      if (updated) { return updated; }
    }
  }
  return null;
}

function updateNoteBodyByTitle(app, title, accountName, folderPath, bodyHTML) {
  var matches = findNotesByTitle(app, title);
  var filtered = [];
  for (var i = 0; i < matches.length; i++) {
    if (accountName && matches[i].accountName !== accountName) { continue; }
    if (folderPath && matches[i].folderPath !== folderPath) { continue; }
    filtered.push(matches[i]);
  }
  if (filtered.length === 0) { return null; }
  if (filtered.length > 1) {
    throw {
      code: 'ambiguous_note_title',
      message: 'Multiple Apple Notes notes match the title fallback. Use noteId after a fresh sync.'
    };
  }
  filtered[0].note.body.set(bodyHTML);
  return safeUpdatedNoteInfo(filtered[0].note, filtered[0].accountName, filtered[0].folderPath, bodyHTML);
}

function updateNoteBodyByIdInFolder(folder, accountName, folderPath, appleNoteId, bodyHTML) {
  var notes = valueOrEmptyArray(function(){ return folder.notes(); });
  for (var i = 0; i < notes.length; i++) {
    var note = notes[i];
    if (valueOrNull(function(){ return note.id(); }) === appleNoteId) {
      note.body.set(bodyHTML);
      return safeUpdatedNoteInfo(note, accountName, folderPath, bodyHTML);
    }
  }
  var folders = foldersOrEmpty(folder, null, folderPath);
  for (var j = 0; j < folders.length; j++) {
    var child = folders[j];
    var childName = valueOrNull(function(){ return child.name(); });
    if (!childName) { continue; }
    var updated = updateNoteBodyByIdInFolder(child, accountName, folderPath + '/' + childName, appleNoteId, bodyHTML);
    if (updated) { return updated; }
  }
  return null;
}

function moveNoteById(app, appleNoteId, targetFolder, targetAccountName, targetFolderPath) {
  var accounts = app.accounts();
  for (var i = 0; i < accounts.length; i++) {
    var accountName = valueOrNull(function(){ return accounts[i].name(); });
    if (!accountName) { continue; }
    var folders = foldersOrEmpty(accounts[i], null, '');
    for (var j = 0; j < folders.length; j++) {
      var folderName = valueOrNull(function(){ return folders[j].name(); });
      if (!folderName) { continue; }
      var moved = moveNoteByIdInFolder(folders[j], appleNoteId, targetFolder, targetAccountName, targetFolderPath);
      if (moved) { return moved; }
    }
  }
  return null;
}

function moveNoteByIdInFolder(folder, appleNoteId, targetFolder, targetAccountName, targetFolderPath) {
  var notes = valueOrEmptyArray(function(){ return folder.notes(); });
  for (var i = 0; i < notes.length; i++) {
    var note = notes[i];
    if (valueOrNull(function(){ return note.id(); }) === appleNoteId) {
      note.move({ to: targetFolder });
      return {
        appleNoteId: appleNoteId,
        accountName: targetAccountName,
        folderPath: targetFolderPath
      };
    }
  }
  var folders = foldersOrEmpty(folder, null, '');
  for (var j = 0; j < folders.length; j++) {
    var moved = moveNoteByIdInFolder(folders[j], appleNoteId, targetFolder, targetAccountName, targetFolderPath);
    if (moved) { return moved; }
  }
  return null;
}

function moveNoteByTitle(app, title, sourceAccountName, sourceFolderPath, targetFolder, targetAccountName, targetFolderPath) {
  var matches = findNotesByTitle(app, title);
  var filtered = [];
  for (var i = 0; i < matches.length; i++) {
    if (sourceAccountName && matches[i].accountName !== sourceAccountName) { continue; }
    if (sourceFolderPath && matches[i].folderPath !== sourceFolderPath) { continue; }
    filtered.push(matches[i]);
  }
  if (filtered.length === 0) { return null; }
  if (filtered.length > 1) {
    throw {
      code: 'ambiguous_note_title',
      message: 'Multiple Apple Notes notes match the move fallback. Use noteId after a fresh sync.'
    };
  }
  var appleNoteId = valueOrNull(function(){ return filtered[0].note.id(); });
  filtered[0].note.move({ to: targetFolder });
  return {
    appleNoteId: appleNoteId,
    accountName: targetAccountName,
    folderPath: targetFolderPath
  };
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
