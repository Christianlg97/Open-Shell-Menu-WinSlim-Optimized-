// Classic Shell (c) 2009-2017, Ivo Beltchev
// Open-Shell (c) 2017-2018, The Open-Shell Team
// Confidential information of Ivo Beltchev. Not for disclosure or distribution without prior written consent from the author

// LogManager.cpp - logging functionality (for debugging)

#include "stdafx.h"
#include "LogManager.h"
#include "ResourceHelper.h"
#include "ComHelper.h"
#include <propvarutil.h>
#include <chrono>
#include <atomic>

int g_LogCategories;
static FILE *g_LogFile;
static std::chrono::time_point<std::chrono::steady_clock> g_LogTime;

void InitLog( int categories, const wchar_t *fname )
{
	CloseLog();
	if (categories==0) return;
	if (_wfopen_s(&g_LogFile,fname,L"wb")==0)
	{
		wchar_t bom=0xFEFF;
		fwrite(&bom,2,1,g_LogFile);
		g_LogCategories=categories;
		g_LogTime=std::chrono::steady_clock::now();
		LogMessage(L"version=%x, PID=%d, TID=%d, Categories=%08x\r\n",GetWinVersion(),GetCurrentProcessId(),GetCurrentThreadId(),categories);
	}
}

void CloseLog( void )
{
	if (g_LogFile) fclose(g_LogFile);
	g_LogFile=NULL;
	g_LogCategories=0;
}

void LogMessage( const wchar_t *text, ... )
{
	if (!g_LogFile) return;

	wchar_t buf[2048];
	int len=Sprintf(buf,_countof(buf),L"%8d: ",std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-g_LogTime).count());
	fwrite(buf,2,len,g_LogFile);

	va_list args;
	va_start(args,text);
	len=Vsprintf(buf,_countof(buf),text,args);
	va_end(args);
	fwrite(buf,2,len,g_LogFile);

	fwrite(L"\r\n",2,2,g_LogFile);

	fflush(g_LogFile);
}

void LogPropertyStore(TLogCategory category, IPropertyStore* store)
{
	if (!store)
		return;

	DWORD count = 0;
	store->GetCount(&count);
	for (DWORD i = 0; i < count; i++)
	{
		PROPERTYKEY key{};
		store->GetAt(i, &key);

		PROPVARIANT val;
		PropVariantInit(&val);

		store->GetValue(key, &val);

		CComString valueStr;
		PropVariantToStringAlloc(val, &valueStr);
		PropVariantClear(&val);

		wchar_t guidStr[100]{};
		StringFromGUID2(key.fmtid, guidStr, _countof(guidStr));

		LOG_MENU(category, L"Property: {%s, %u} = %s", guidStr, key.pid, valueStr ? valueStr : L"???");
	}
}

namespace
{
	struct InteractionRecord
	{
		ULONGLONG sequence, time;
		DWORD thread;
		TInteractionTrace event;
		HWND window, foreground;
		UINT message;
		WPARAM wParam;
		LPARAM lParam;
		wchar_t windowClass[64], foregroundClass[64], activatedClass[64];
	};
	SRWLOCK g_InteractionLock=SRWLOCK_INIT;
	InteractionRecord g_InteractionRecords[256]={};
	ULONGLONG g_InteractionSequence=0, g_InteractionFlushed=0;
	std::atomic<bool> g_InteractionEnabled{false};
	volatile LONG g_InteractionFlushPending=0;

	DWORD WINAPI FlushInteractionTrace( void *param )
	{
		InteractionRecord snapshot[256];
		AcquireSRWLockExclusive(&g_InteractionLock);
		ULONGLONG first=g_InteractionSequence>256?g_InteractionSequence-256:0;
		if (first<g_InteractionFlushed) first=g_InteractionFlushed;
		ULONGLONG last=g_InteractionSequence;
		for (ULONGLONG i=first;i<last;i++) snapshot[i-first]=g_InteractionRecords[i%256];
		ReleaseSRWLockExclusive(&g_InteractionLock);
		wchar_t path[MAX_PATH]=L"%LOCALAPPDATA%\\OpenShell\\InteractionTrace.log";
		DoEnvironmentSubst(path,_countof(path));
		wchar_t directory[MAX_PATH];
		Strcpy(directory,_countof(directory),path);
		PathRemoveFileSpec(directory);
		CreateDirectory(directory,NULL);
		WIN32_FILE_ATTRIBUTE_DATA attributes={};
		bool truncate=GetFileAttributesEx(path,GetFileExInfoStandard,&attributes) &&
			(attributes.nFileSizeHigh || attributes.nFileSizeLow>4*1024*1024);
		FILE *file=NULL;
		if (_wfopen_s(&file,path,truncate?L"wb":L"ab")==0 && file)
		{
			for (ULONGLONG i=0;i<last-first;i++)
			{
				const auto &r=snapshot[i];
				fprintf(file,"seq=%llu tick=%llu tid=%lu event=%d hwnd=%p fg=%p msg=%04X wp=%llX lp=%llX\r\n",
					r.sequence,r.time,r.thread,r.event,r.window,r.foreground,r.message,(unsigned long long)r.wParam,(unsigned long long)r.lParam);
				fprintf(file,"  class=%ls foreground=%ls activated=%ls\r\n",r.windowClass,r.foregroundClass,r.activatedClass);
			}
			fclose(file);
			AcquireSRWLockExclusive(&g_InteractionLock);
			g_InteractionFlushed=last;
			ReleaseSRWLockExclusive(&g_InteractionLock);
		}
		InterlockedExchange(&g_InteractionFlushPending,0);
		FreeLibraryAndExitThread((HMODULE)param,0);
		return 0;
	}
}

void InitializeInteractionTrace( void )
{
	DWORD enabled=0, size=sizeof(enabled);
	RegGetValue(HKEY_CURRENT_USER,L"Software\\OpenShell\\StartMenu\\Settings",L"TraceInteractions",RRF_RT_REG_DWORD,NULL,&enabled,&size);
	g_InteractionEnabled=enabled!=0;
}

void TraceInteraction( TInteractionTrace event, HWND window, UINT message, WPARAM wParam, LPARAM lParam )
{
	if (!g_InteractionEnabled || !TryAcquireSRWLockExclusive(&g_InteractionLock)) return;
	ULONGLONG index=g_InteractionSequence++;
	g_InteractionRecords[index%256]={index+1,GetTickCount64(),GetCurrentThreadId(),event,window,GetForegroundWindow(),message,wParam,lParam};
	InteractionRecord &record=g_InteractionRecords[index%256];
	GetClassName(window,record.windowClass,_countof(record.windowClass));
	GetClassName(record.foreground,record.foregroundClass,_countof(record.foregroundClass));
	if (event==TRACE_MENU_DEACTIVATE || event==TRACE_OWNER_DEACTIVATE)
		GetClassName((HWND)lParam,record.activatedClass,_countof(record.activatedClass));
	ReleaseSRWLockExclusive(&g_InteractionLock);
}

void QueueInteractionTraceFlush( void )
{
	if (!g_InteractionEnabled || InterlockedCompareExchange(&g_InteractionFlushPending,1,0)!=0) return;
	HMODULE module=NULL;
	if (!GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,(LPCWSTR)&FlushInteractionTrace,&module))
	{
		InterlockedExchange(&g_InteractionFlushPending,0);
		return;
	}
	HANDLE thread=CreateThread(NULL,0,FlushInteractionTrace,module,0,NULL);
	if (thread) CloseHandle(thread);
	else
	{
		FreeLibrary(module);
		InterlockedExchange(&g_InteractionFlushPending,0);
	}
}
