#include "SQLiteVecBridge.h"
#include "sqlite-vec.h"

int AppleNotesMCPRegisterSQLiteVec(sqlite3 *db) {
    return sqlite3_vec_init(db, 0, 0);
}

const char *AppleNotesMCPSQLiteVecVersion(void) {
    return SQLITE_VEC_VERSION;
}
