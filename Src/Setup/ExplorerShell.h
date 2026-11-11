// Open-Shell for WinSlim: stops and restarts the Explorer shell around an installation, like
// the WinSlim Toolbox command "taskkill /f /im explorer.exe & start explorer.exe", but limited
// to the installing user's session and without leaving an elevated taskbar behind.
// Shared by Setup.exe (bootstrapper fallback) and SetupHelper.exe (MSI custom actions).

#pragma once

#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>

namespace ExplorerShell
{
	// Volatile marker (gone at logoff) created directly under HKCU\Software: a volatile key
	// must never become the parent of Open-Shell's persistent settings.
	const wchar_t STOPPED_MARKER[]=L"Software\\OpenShellSetupStoppedExplorer";
	// The message behind the taskbar's "Exit Explorer" command: a clean shutdown.
	const UINT WM_EXIT_EXPLORER=WM_USER+436;
	const DWORD EXIT_TIMEOUT=3000, TERMINATE_TIMEOUT=5000, TASKBAR_TIMEOUT=15000;
	const TOKEN_INFORMATION_CLASS TOKEN_IS_APP_CONTAINER=(TOKEN_INFORMATION_CLASS)29; // TokenIsAppContainer (Windows 8+)

	inline bool GetSession( DWORD processId, DWORD &session )
	{
		return ProcessIdToSessionId(processId,&session)!=FALSE;
	}

	inline bool IsExplorerImage( DWORD processId )
	{
		HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,processId);
		if (!process) return false;
		wchar_t path[MAX_PATH];
		DWORD size=_countof(path);
		bool explorer=false;
		if (QueryFullProcessImageName(process,0,path,&size))
		{
			const wchar_t *name=wcsrchr(path,L'\\');
			explorer=_wcsicmp(name?name+1:path,L"explorer.exe")==0;
		}
		CloseHandle(process);
		return explorer;
	}

	// True when the window belongs to an explorer.exe running in this process's session.
	inline bool IsSessionExplorerWindow( HWND window )
	{
		DWORD processId=0, session=0, current=0;
		if (!window) return false;
		GetWindowThreadProcessId(window,&processId);
		return processId && GetSession(processId,session) && GetSession(GetCurrentProcessId(),current) &&
			session==current && IsExplorerImage(processId);
	}

	inline bool IsShellRunning( void ) { return IsSessionExplorerWindow(GetShellWindow()); }
	inline bool IsTaskbarReady( void ) { return IsSessionExplorerWindow(FindWindow(L"Shell_TrayWnd",NULL)); }

	// Asks the taskbar to exit cleanly, then terminates every explorer.exe left in this session
	// (folder windows in separate processes, or a shell that ignored the request).
	// Returns true when Explorer was running here.
	inline bool Stop( void )
	{
		DWORD current=0;
		if (!GetSession(GetCurrentProcessId(),current)) return false;
		bool stopped=false;
		HWND tray=FindWindow(L"Shell_TrayWnd",NULL);
		if (IsSessionExplorerWindow(tray))
		{
			DWORD processId=0;
			GetWindowThreadProcessId(tray,&processId);
			HANDLE process=OpenProcess(SYNCHRONIZE,FALSE,processId);
			stopped=true;
			if (PostMessage(tray,WM_EXIT_EXPLORER,0,0) && process)
				WaitForSingleObject(process,EXIT_TIMEOUT);
			if (process) CloseHandle(process);
		}
		HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
		if (snapshot!=INVALID_HANDLE_VALUE)
		{
			PROCESSENTRY32W entry={sizeof(entry)};
			for (BOOL more=Process32FirstW(snapshot,&entry);more;more=Process32NextW(snapshot,&entry))
			{
				DWORD session=0;
				if (_wcsicmp(entry.szExeFile,L"explorer.exe")!=0 || !GetSession(entry.th32ProcessID,session) || session!=current)
					continue;
				HANDLE process=OpenProcess(PROCESS_TERMINATE|SYNCHRONIZE,FALSE,entry.th32ProcessID);
				if (!process) continue;
				stopped=true;
				if (TerminateProcess(process,1))
					WaitForSingleObject(process,TERMINATE_TIMEOUT);
				CloseHandle(process);
			}
			CloseHandle(snapshot);
		}
		return stopped;
	}

	inline void SetStoppedMark( void )
	{
		HKEY key=NULL;
		if (RegCreateKeyEx(HKEY_CURRENT_USER,STOPPED_MARKER,0,NULL,REG_OPTION_VOLATILE,KEY_WRITE,NULL,&key,NULL)==ERROR_SUCCESS)
			RegCloseKey(key);
	}

	// Consumes the marker: true when this setup had stopped the shell.
	inline bool TakeStoppedMark( void )
	{
		return RegDeleteKey(HKEY_CURRENT_USER,STOPPED_MARKER)==ERROR_SUCCESS;
	}

	inline bool QueryToken( HANDLE token, TOKEN_INFORMATION_CLASS type, void *buffer, DWORD size )
	{
		DWORD returned=0;
		return GetTokenInformation(token,type,buffer,size,&returned)!=FALSE;
	}

	// A medium-integrity, unrestricted, non-AppContainer limited token of the given user.
	inline bool IsLimitedUserToken( HANDLE token, PSID user )
	{
		TOKEN_ELEVATION_TYPE type=TokenElevationTypeDefault;
		if (!QueryToken(token,TokenElevationType,&type,sizeof(type)) || type!=TokenElevationTypeLimited) return false;
		DWORD_PTR userBuffer[(sizeof(TOKEN_USER)+SECURITY_MAX_SID_SIZE)/sizeof(DWORD_PTR)+1];
		if (!QueryToken(token,TokenUser,userBuffer,sizeof(userBuffer)) || !EqualSid(((TOKEN_USER*)userBuffer)->User.Sid,user)) return false;
		if (IsTokenRestricted(token)) return false;
		DWORD appContainer=0;
		if (QueryToken(token,TOKEN_IS_APP_CONTAINER,&appContainer,sizeof(appContainer)) && appContainer) return false;
		DWORD_PTR labelBuffer[(sizeof(TOKEN_MANDATORY_LABEL)+SECURITY_MAX_SID_SIZE)/sizeof(DWORD_PTR)+1];
		if (!QueryToken(token,TokenIntegrityLevel,labelBuffer,sizeof(labelBuffer))) return false;
		PSID label=((TOKEN_MANDATORY_LABEL*)labelBuffer)->Label.Sid;
		return *GetSidSubAuthority(label,*GetSidSubAuthorityCount(label)-1)==SECURITY_MANDATORY_MEDIUM_RID;
	}

	inline HANDLE DuplicateLimitedProcessToken( DWORD processId, PSID user )
	{
		HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,processId);
		if (!process) return NULL;
		HANDLE token=NULL, primary=NULL;
		if (OpenProcessToken(process,TOKEN_QUERY|TOKEN_DUPLICATE,&token))
		{
			if (!IsLimitedUserToken(token,user) ||
				!DuplicateTokenEx(token,TOKEN_QUERY|TOKEN_DUPLICATE|TOKEN_ASSIGN_PRIMARY|TOKEN_ADJUST_DEFAULT|TOKEN_ADJUST_SESSIONID,NULL,SecurityImpersonation,TokenPrimary,&primary))
				primary=NULL;
			CloseHandle(token);
		}
		CloseHandle(process);
		return primary;
	}

	// Explorer must not inherit an elevated split token. When this process runs elevated, borrow
	// the limited token of another process of the same user in this session: preferably the
	// shell infrastructure host started with the logon (sihost.exe), otherwise any equivalent.
	// Returns NULL when the process is not elevated through UAC or no such process exists.
	inline HANDLE DuplicateLimitedSessionToken( void )
	{
		HANDLE self=NULL;
		if (!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&self)) return NULL;
		TOKEN_ELEVATION_TYPE type=TokenElevationTypeDefault;
		DWORD_PTR userBuffer[(sizeof(TOKEN_USER)+SECURITY_MAX_SID_SIZE)/sizeof(DWORD_PTR)+1];
		bool elevated=QueryToken(self,TokenElevationType,&type,sizeof(type)) && type==TokenElevationTypeFull &&
			QueryToken(self,TokenUser,userBuffer,sizeof(userBuffer));
		CloseHandle(self);
		DWORD current=0;
		if (!elevated || !GetSession(GetCurrentProcessId(),current)) return NULL;
		PSID user=((TOKEN_USER*)userBuffer)->User.Sid;
		HANDLE result=NULL;
		HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
		if (snapshot==INVALID_HANDLE_VALUE) return NULL;
		for (int pass=0;pass<2 && !result;pass++)
		{
			PROCESSENTRY32W entry={sizeof(entry)};
			for (BOOL more=Process32FirstW(snapshot,&entry);more && !result;more=Process32NextW(snapshot,&entry))
			{
				DWORD session=0;
				if (entry.th32ProcessID==GetCurrentProcessId() || (pass==0 && _wcsicmp(entry.szExeFile,L"sihost.exe")!=0) ||
					!GetSession(entry.th32ProcessID,session) || session!=current)
					continue;
				result=DuplicateLimitedProcessToken(entry.th32ProcessID,user);
			}
		}
		CloseHandle(snapshot);
		return result;
	}

	// Starts explorer.exe as the session shell, unelevated whenever a limited token exists.
	inline bool Start( void )
	{
		wchar_t path[MAX_PATH];
		const wchar_t name[]=L"\\explorer.exe";
		UINT length=GetWindowsDirectory(path,_countof(path));
		if (!length || length+_countof(name)>_countof(path)) return false;
		wcscpy_s(path+length,_countof(path)-length,name);
		wchar_t desktop[]=L"winsta0\\default";
		STARTUPINFOW startupInfo={sizeof(startupInfo)};
		PROCESS_INFORMATION processInfo={};
		bool started=false;
		if (HANDLE token=DuplicateLimitedSessionToken())
		{
			startupInfo.lpDesktop=desktop;
			started=CreateProcessWithTokenW(token,0,path,NULL,0,NULL,NULL,&startupInfo,&processInfo)!=FALSE;
			CloseHandle(token);
		}
		if (!started)
		{
			// No UAC split token (or no Secondary Logon service): same as "start explorer.exe".
			startupInfo.lpDesktop=NULL;
			started=CreateProcessW(path,NULL,NULL,NULL,FALSE,0,NULL,NULL,&startupInfo,&processInfo)!=FALSE;
		}
		if (!started) return false;
		CloseHandle(processInfo.hThread);
		CloseHandle(processInfo.hProcess);
		return true;
	}

	inline bool WaitForTaskbar( DWORD timeout )
	{
		for (DWORD waited=0;;waited+=100)
		{
			if (IsTaskbarReady()) return true;
			if (waited>=timeout) return false;
			Sleep(100);
		}
	}

	// Brings back a shell this setup stopped, once. The marker is consumed, so the success
	// path, the rollback path and the bootstrapper fallback never start Explorer twice.
	inline void RestartIfStopped( void )
	{
		if (!TakeStoppedMark() || IsShellRunning()) return;
		if (Start()) WaitForTaskbar(TASKBAR_TIMEOUT);
	}
}
