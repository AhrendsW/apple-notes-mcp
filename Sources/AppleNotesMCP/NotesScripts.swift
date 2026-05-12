import Foundation

extension NotesService {
    static let scriptListAccounts = #"""
    var app = notesApp();
    var accounts = app.accounts();
    var out = [];
    for (var i = 0; i < accounts.length; i++) {
      out.push({ name: accounts[i].name() });
    }
    return ok({ accounts: out });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptListFolders = #"""
    var app = notesApp();
    var out = [];
    var warnings = [];
    if (input.accountName) {
      var account = accountByName(app, input.accountName);
      collectFolders(account, input.accountName, '', out, warnings);
    } else {
      var accounts = app.accounts();
      for (var i = 0; i < accounts.length; i++) {
        var accountName = valueOrNull(function(){ return accounts[i].name(); });
        if (!accountName) {
          warnings.push({ code: 'account_reference_unavailable', path: null });
          continue;
        }
        collectFolders(accounts[i], String(accountName), '', out, warnings);
      }
    }
    return ok({ folders: out, warnings: warnings });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptCreateFolder = #"""
    var app = notesApp();
    var account = accountByName(app, input.accountName);
    var result = getFolder(app, account, input.folderPath, true);
    return ok({
      accountName: input.accountName,
      folderPath: result.path,
      existing: result.existing
    });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptRenameFolder = #"""
    var app = notesApp();
    var account = accountByName(app, input.accountName);
    var result = getFolder(app, account, input.folderPath, false);
    var parts = splitPath(result.path);
    if (!input.newName || String(input.newName).indexOf('/') >= 0) {
      return fail('invalid_params', 'newName must be a folder name, not a path.', {});
    }
    var parentPath = parts.slice(0, Math.max(0, parts.length - 1)).join('/');
    var parent = parentPath ? getFolder(app, account, parentPath, false).folder : account;
    var currentName = result.folder.name();
    if (currentName !== input.newName && findChildFolder(parent, input.newName)) {
      return fail('folder_already_exists', 'A folder with the target name already exists.', {});
    }
    result.folder.name.set(input.newName);
    var newPath = parentPath ? parentPath + '/' + input.newName : input.newName;
    return ok({
      accountName: input.accountName,
      oldPath: result.path,
      folderPath: newPath,
      name: input.newName
    });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptCreateNote = #"""
    var app = notesApp();
    var account = accountByName(app, input.accountName);
    var folderResult = getFolder(app, account, input.folderPath, true);
    var note = app.Note({ name: input.title, body: input.bodyHTML });
    folderResult.folder.notes.push(note);
    return ok(noteInfo(note, input.accountName, folderResult.path, true));
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptReadNote = #"""
    var app = notesApp();
    var found = findNoteById(app, input.appleNoteId);
    if (!found) {
      return fail('note_not_found', 'Apple Notes note not found.', { appleNoteId: input.appleNoteId });
    }
    return ok(noteInfo(found.note, found.accountName, found.folderPath, true));
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptUpdateNote = #"""
    var app = notesApp();
    var found = findNoteById(app, input.appleNoteId);
    if (!found) {
      return fail('note_not_found', 'Apple Notes note not found.', { appleNoteId: input.appleNoteId });
    }
    found.note.body.set(input.bodyHTML);
    return ok(noteInfo(found.note, found.accountName, found.folderPath, true));
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptRenameNote = #"""
    var app = notesApp();
    var found = findNoteById(app, input.appleNoteId);
    if (!found) {
      return fail('note_not_found', 'Apple Notes note not found.', { appleNoteId: input.appleNoteId });
    }
    found.note.name.set(input.newTitle);
    if (input.bodyHTML !== null && input.bodyHTML !== undefined) {
      found.note.body.set(input.bodyHTML);
    }
    return ok(noteInfo(found.note, found.accountName, found.folderPath, true));
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptDeleteNote = #"""
    var app = notesApp();
    var found = findNoteById(app, input.appleNoteId);
    if (!found) {
      return fail('note_not_found', 'Apple Notes note not found.', { appleNoteId: input.appleNoteId });
    }
    app.delete(found.note);
    return ok({ deleted: true, appleNoteId: input.appleNoteId });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptMoveFolder = #"""
    var app = notesApp();
    var sourceAccount = accountByName(app, input.accountName);
    var source = getFolder(app, sourceAccount, input.folderPath, false);
    var targetAccountName = input.targetAccountName || input.accountName;
    var targetAccount = accountByName(app, targetAccountName);
    var targetParent = getFolderContainer(app, targetAccount, input.targetParentFolderPath, input.createFolderIfMissing);
    var newName = input.newName || source.folder.name();
    if (String(newName).indexOf('/') >= 0) {
      return fail('invalid_params', 'newName must be a folder name, not a path.', {});
    }
    if (input.accountName === targetAccountName
        && (targetParent.path === source.path || targetParent.path.indexOf(source.path + '/') === 0)) {
      return fail('invalid_params', 'Cannot move a folder into itself or one of its children.', {});
    }
    if (findChildFolder(targetParent.folder, newName)) {
      return fail('folder_already_exists', 'A folder with the target name already exists in the target parent.', {});
    }
    if (source.folder.name() !== newName) {
      source.folder.name.set(newName);
    }
    source.folder.move({ to: targetParent.folder });
    return ok({
      accountName: targetAccountName,
      oldPath: source.path,
      folderPath: joinFolderPath(targetParent.path, newName),
      name: newName
    });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptDeleteFolder = #"""
    var app = notesApp();
    var account = accountByName(app, input.accountName);
    var result = getFolder(app, account, input.folderPath, false);
    app.delete(result.folder);
    return ok({
      accountName: input.accountName,
      folderPath: result.path,
      deleted: true
    });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptMoveNote = #"""
    var app = notesApp();
    var found = findNoteById(app, input.appleNoteId);
    if (!found) {
      return fail('note_not_found', 'Apple Notes note not found.', { appleNoteId: input.appleNoteId });
    }
    var account = accountByName(app, input.targetAccountName);
    var folderResult = getFolder(app, account, input.targetFolderPath, input.createFolderIfMissing);
    found.note.move({ to: folderResult.folder });
    return ok({
      appleNoteId: input.appleNoteId,
      accountName: input.targetAccountName,
      folderPath: folderResult.path
    });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#

    static let scriptListNotes = #"""
    var app = notesApp();
    var out = [];
    var maxNotes = input.maxNotes || null;
    if (input.accountName) {
      var account = accountByName(app, input.accountName);
      if (input.folderPath) {
        var folderResult = getFolder(app, account, input.folderPath, false);
        collectNotesFromFolder(folderResult.folder, input.accountName, folderResult.path, out, true, maxNotes);
      } else {
        var folders = account.folders();
        for (var i = 0; i < folders.length; i++) {
          if (maxNotes && out.length >= maxNotes) { break; }
          collectNotesFromFolder(folders[i], input.accountName, folders[i].name(), out, true, maxNotes);
        }
      }
    } else {
      var accounts = app.accounts();
      for (var a = 0; a < accounts.length; a++) {
        if (maxNotes && out.length >= maxNotes) { break; }
        var accountName = accounts[a].name();
        var folders2 = accounts[a].folders();
        for (var j = 0; j < folders2.length; j++) {
          if (maxNotes && out.length >= maxNotes) { break; }
          collectNotesFromFolder(folders2[j], accountName, folders2[j].name(), out, true, maxNotes);
        }
      }
    }
    return ok({ notes: out });
  } catch (e) {
    return fail(e.code || 'apple_notes_automation_failed', e.message || String(e), {});
  }
}
"""#
}
