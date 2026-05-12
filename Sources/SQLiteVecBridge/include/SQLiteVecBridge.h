#ifndef SQLITE_VEC_BRIDGE_H
#define SQLITE_VEC_BRIDGE_H

#include <sqlite3.h>

int AppleNotesMCPRegisterSQLiteVec(sqlite3 *db);
const char *AppleNotesMCPSQLiteVecVersion(void);

#endif
