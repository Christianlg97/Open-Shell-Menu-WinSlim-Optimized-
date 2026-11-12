#pragma once

#include <windows.h>

namespace OpenShellFolders
{
	// Wait once for a burst, then rearm every signaled directory before scanning.
	// New changes during the scan remain signaled for the next batch. Stop takes
	// priority and interrupts the debounce; a broken watcher is closed/removed.
	inline bool WaitForChanges( HANDLE stop, HANDLE *directories, DWORD *masks, int &count, DWORD &changed, DWORD delay=1000 )
	{
		changed=0;
		if (count<=0 || count>=MAXIMUM_WAIT_OBJECTS) return false;
		HANDLE waits[MAXIMUM_WAIT_OBJECTS];
		waits[0]=stop;
		for (int i=0;i<count;i++) waits[i+1]=directories[i];
		DWORD result=WaitForMultipleObjects(count+1,waits,FALSE,INFINITE);
		if (result<WAIT_OBJECT_0+1 || result>WAIT_OBJECT_0+count) return false;
		if (WaitForSingleObject(stop,delay)!=WAIT_TIMEOUT) return false;
		for (int i=0;i<count;)
		{
			DWORD state=WaitForSingleObject(directories[i],0);
			if (state==WAIT_OBJECT_0) changed|=masks[i];
			if (state==WAIT_TIMEOUT || (state==WAIT_OBJECT_0 && FindNextChangeNotification(directories[i])))
				i++;
			else
			{
				FindCloseChangeNotification(directories[i]);
				count--;
				directories[i]=directories[count];
				masks[i]=masks[count];
			}
		}
		return changed!=0;
	}
}
