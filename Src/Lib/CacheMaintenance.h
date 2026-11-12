// Regenerable Open-Shell caches only. Never remove the directory or user data.
#pragma once
#include <windows.h>
#include <shlobj.h>
#include <cstdlib>
#include <cwchar>
#pragma comment(lib,"shell32.lib")
#pragma comment(lib,"ole32.lib")
#pragma comment(lib,"advapi32.lib")
#pragma comment(lib,"uuid.lib")

namespace OpenShellCache
{
constexpr wchar_t PendingName[]=L"CacheCleanup.pending";
constexpr wchar_t StateName[]=L"CacheMaintenance.state";
constexpr const wchar_t *Files[]={L"DataCache.db",L"DataCache.tmp",L"ModernSettings.dat",L"DataCache.txt"};

class Handle
{
public:
	explicit Handle(HANDLE value):m_Value(value) {}
	~Handle() { if (Valid()) CloseHandle(m_Value); }
	bool Valid() const { return m_Value!=NULL && m_Value!=INVALID_HANDLE_VALUE; }
	operator HANDLE() const { return m_Value; }
	Handle(const Handle&)=delete;
	Handle &operator=(const Handle&)=delete;
private:
	HANDLE m_Value;
};

inline bool Join(wchar_t (&path)[MAX_PATH],const wchar_t *folder,const wchar_t *name)
{
	if (wcslen(folder)+wcslen(name)+2>MAX_PATH) return false;
	wcscpy_s(path,folder);
	wcscat_s(path,L"\\");
	wcscat_s(path,name);
	return true;
}
inline bool RegularFile(DWORD attributes)
{
	return attributes!=INVALID_FILE_ATTRIBUTES && !(attributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT));
}
inline bool RegularHandle(HANDLE file)
{
	BY_HANDLE_FILE_INFORMATION info={};
	return GetFileInformationByHandle(file,&info) && RegularFile(info.dwFileAttributes);
}
inline bool SafeDirectory(const wchar_t *folder)
{
	wchar_t path[MAX_PATH];
	if (wcslen(folder)>=MAX_PATH || wcslen(folder)<3 || folder[1]!=L':' || folder[2]!=L'\\') return false;
	wcscpy_s(path,folder);
	for (;;)
	{
		DWORD attributes=GetFileAttributesW(path);
		if (attributes==INVALID_FILE_ATTRIBUTES || !(attributes&FILE_ATTRIBUTE_DIRECTORY) || (attributes&FILE_ATTRIBUTE_REPARSE_POINT)) return false;
		if (wcslen(path)==3) return true;
		wchar_t *end=wcsrchr(path,L'\\');
		if (!end) return false;
		if (end==path+2) end[1]=0;
		else *end=0;
	}
}
inline bool ReadGeneration(wchar_t (&generation)[256])
{
	generation[0]=0;
	HKEY key=NULL;
	if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"Software\\OpenShell\\OpenShell",0,KEY_QUERY_VALUE|KEY_WOW64_64KEY,&key)!=ERROR_SUCCESS) return false;
	DWORD size=sizeof(generation),type=0;
	LSTATUS result=RegQueryValueExW(key,L"CacheGeneration",NULL,&type,(BYTE*)generation,&size);
	RegCloseKey(key);
	if (result!=ERROR_SUCCESS || type!=REG_SZ || size<sizeof(wchar_t) || size>sizeof(generation) || size%sizeof(wchar_t) || generation[size/sizeof(wchar_t)-1]!=0)
	{
		generation[0]=0;
		return false;
	}
	return generation[0]!=0;
}
inline bool ReadState(const wchar_t *path,wchar_t (&state)[256])
{
	state[0]=0;
	Handle file(CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,NULL));
	LARGE_INTEGER size={};
	if (!file.Valid() || !RegularHandle(file) || !GetFileSizeEx(file,&size) || size.QuadPart<2 || size.QuadPart>sizeof(state) || size.QuadPart%2) return false;
	DWORD read=0;
	return ReadFile(file,state,(DWORD)size.QuadPart,&read,NULL) && read==size.QuadPart && state[read/sizeof(wchar_t)-1]==0;
}
inline bool Request(const wchar_t *path)
{
	Handle file(CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_DELETE,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,NULL));
	if (file.Valid()) return RegularHandle(file);
	return GetLastError()==ERROR_FILE_EXISTS && RegularFile(GetFileAttributesW(path));
}
inline bool DeleteCache(const wchar_t *path)
{
	DWORD attributes=GetFileAttributesW(path);
	if (attributes==INVALID_FILE_ATTRIBUTES)
	{
		DWORD error=GetLastError();
		return error==ERROR_FILE_NOT_FOUND || error==ERROR_PATH_NOT_FOUND;
	}
	// No recursive removal, attribute changes, force-close, or reboot scheduling.
	return RegularFile(attributes) && DeleteFileW(path)!=FALSE;
}
inline bool WriteState(const wchar_t *folder,const wchar_t *generation)
{
	wchar_t temporary[MAX_PATH],state[MAX_PATH];
	if (!Join(temporary,folder,L"CacheMaintenance.state.tmp") || !Join(state,folder,StateName) || !DeleteCache(temporary)) return false;
	DWORD attributes=GetFileAttributesW(state);
	if (attributes!=INVALID_FILE_ATTRIBUTES && !RegularFile(attributes)) return false;
	bool ok=false;
	{
		Handle file(CreateFileW(temporary,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,NULL));
		if (!file.Valid() || !RegularHandle(file)) return false;
		DWORD size=(DWORD)((wcslen(generation)+1)*sizeof(wchar_t)),written=0;
		ok=WriteFile(file,generation,size,&written,NULL) && written==size && FlushFileBuffers(file);
	}
	if (ok) ok=MoveFileExW(temporary,state,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=FALSE;
	if (!ok) DeleteCache(temporary);
	return ok;
}

// folder is the current user's known LocalAppData\OpenShell directory. Kept
// separate for isolated native regressions: no profile enumeration or HKCU edits.
inline DWORD MaintainFolder(const wchar_t *folder,const wchar_t *generation,bool force)
{
	if (!SafeDirectory(folder)) return ERROR_ACCESS_DENIED;
	const wchar_t *name=wcsrchr(folder,L'\\');
	if (!name || _wcsicmp(name+1,L"OpenShell")!=0) return ERROR_INVALID_NAME;
	Handle directory(CreateFileW(folder,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,NULL));
	BY_HANDLE_FILE_INFORMATION info={};
	if (!directory.Valid() || !GetFileInformationByHandle(directory,&info) || (info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_ACCESS_DENIED;
	wchar_t pending[MAX_PATH],statePath[MAX_PATH],state[256];
	if (!Join(pending,folder,PendingName) || !Join(statePath,folder,StateName)) return ERROR_FILENAME_EXCED_RANGE;
	DWORD pendingAttributes=GetFileAttributesW(pending);
	bool requested=pendingAttributes!=INVALID_FILE_ATTRIBUTES;
	if (requested && !RegularFile(pendingAttributes)) return ERROR_ACCESS_DENIED;
	if (!force && !requested && (!generation[0] || (ReadState(statePath,state) && wcscmp(state,generation)==0))) return ERROR_SUCCESS;
	if (!Request(pending)) return ERROR_ACCESS_DENIED;
	wchar_t lockPath[MAX_PATH];
	if (!Join(lockPath,folder,L"CacheMaintenance.lock")) return ERROR_FILENAME_EXCED_RANGE;
	Handle lock(CreateFileW(lockPath,GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,NULL));
	if (!lock.Valid() || !RegularHandle(lock)) return ERROR_SHARING_VIOLATION;
	bool complete=true;
	for (const wchar_t *file:Files)
	{
		wchar_t path[MAX_PATH];
		if (!Join(path,folder,file) || !DeleteCache(path)) complete=false;
	}
	if (!complete || !WriteState(folder,generation)) return ERROR_SHARING_VIOLATION;
	return DeleteCache(pending)?ERROR_SUCCESS:ERROR_ACCESS_DENIED;
}

inline DWORD MaintainCurrentUser(bool force=false)
{
	wchar_t generation[256];
	ReadGeneration(generation);
	PWSTR local=NULL;
	if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,KF_FLAG_DONT_VERIFY,NULL,&local)))
	{
		CoTaskMemFree(local);
		return ERROR_PATH_NOT_FOUND;
	}
	wchar_t parent[MAX_PATH],folder[MAX_PATH];
	bool copied=wcslen(local)<MAX_PATH;
	if (copied) wcscpy_s(parent,local);
	CoTaskMemFree(local);
	if (!copied || !SafeDirectory(parent) || !Join(folder,parent,L"OpenShell")) return ERROR_ACCESS_DENIED;
	if (GetFileAttributesW(folder)==INVALID_FILE_ATTRIBUTES)
	{
		if (!force && !generation[0]) return ERROR_SUCCESS;
		if (!CreateDirectoryW(folder,NULL) && GetLastError()!=ERROR_ALREADY_EXISTS) return ERROR_ACCESS_DENIED;
	}
	return MaintainFolder(folder,generation,force);
}
}
