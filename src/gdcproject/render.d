// Copyright (C) 2014  Iain Buclaw

// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 3.0 of the License, or (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.

// You should have received a copy of the GNU Lesser General Public
// License along with this program; if not, see
// <http://www.gnu.org/licenses/lgpl-3.0.txt>.

// The gdcproject website powered by vibe.d

// This file builds (and optionally caches) pages to be sent to the client.

module gdcproject.render;

import vibe.inet.path;
import vibe.core.file;
import vibe.db.redis.redis;

import gdcproject.downloads;

// Read and return as a string the (hard coded) header template.
// The template is assumed to be in html format.

string readHeader()
{
  scope(failure) return "<html><body>";
  return readContents("templates/header.inc");
}

// Read and return as a string the (hard coded) footer template.
// The template is assumed to be in html format.

string readFooter()
{
  scope(failure) return "</body></hmtl>";
  return readContents("templates/footer.inc");
}

// Read return as a string the contents of the file in 'path'.

string readContents(string path)
{
  import std.file : read;
  return cast(string) read(path);
}

// Render the page contents to send to client.

string renderPage(string path, string function(string) read, bool nocache = false)
{
  import std.array : appender;
  import vibe.textfilter.markdown : filterMarkdown;

  // First attempt to get from cache.
  if (!nocache)
  {
    scope(failure) goto Lnocache;

    RedisClient rc = connectRedis("127.0.0.1");
    RedisDatabase rdb = rc.getDatabase(0);
    string content = rdb.get!string(path);
    rc.quit();

    if (content != null)
      return content;
  }
Lnocache:

  auto content = appender!string();
  content ~= readHeader();
  content ~= filterMarkdown(read(path));
  content ~= readFooter();

  return content.data;
}

// Watch the views directory, recompiling pages when a change occurs.
// Uses Redis as the database backend.

void waitForViewChanges()
{
  import core.thread : Thread;
  import core.time : seconds;
  scope(failure) return;

  DirectoryWatcher watcher = Path("views").watchDirectory(true);
  while (true)
  {
    DirectoryChange[] changes;
    if (watcher.readChanges(changes, 0.seconds))
    {
      RedisClient rc = connectRedis("127.0.0.1");
      RedisDatabase rdb = rc.getDatabase(0);

      foreach (change; changes)
      {
        string path = change.path.toNativeString();

        // Check if one of the downloads templates changed.
        // Don't handle delete signals.
        if ((path.length == 20 && path == "views/downloads.json")
            || (path.length == 24 && path == "views/downloads.mustache"))
        {
	  path = "views/downloads";
          string content = renderPage(path, &renderDownloadsPage, true);
          rdb.set(path, content);
        }

        // Should be a markdown file.
        if (path.length <= 9 || path[$-3..$] != ".md")
          continue;

        // Add or remove pages on the fly.
        if (change.type == DirectoryChangeType.added
            || change.type == DirectoryChangeType.modified)
        {
          string content = renderPage(path, &readContents, true);
          rdb.set(path, content);
        }
        else if (DirectoryChangeType.removed)
          rdb.del(path);
      }
      rc.quit();
    }
    Thread.sleep(5.seconds);
  }
}

// Watch the templates directory, rebuilding all pages when a change occurs.

void waitForTemplateChanges()
{
  import core.thread : Thread;
  import core.time : seconds;
  scope(failure) return;

  DirectoryWatcher watcher = Path("templates").watchDirectory(false);
  while (true)
  {
    DirectoryChange[] changes;
    if (watcher.readChanges(changes, 0.seconds))
    {
      // Check the name of the file changed, only need to rebuild
      // if either the header or footer change.
      foreach (change; changes)
      {
        string path = change.path.toNativeString();
        if (path.length == 20
            && (path == "templates/header.inc" || path == "templates/footer.inc"))
        {
          buildCache();
          break;
        }
      }
    }
    Thread.sleep(5.seconds);
  }
}

// Render and cache all pages.  This is called on application start-up,
// and when a change occurs to a header/footer template.

void buildCache()
{
  import std.file : dirEntries, SpanMode;
  scope(failure) return;

  RedisClient rc = connectRedis("127.0.0.1");
  RedisDatabase rdb = rc.getDatabase(0);

  // Build all markdown pages.
  auto de = dirEntries("views", "*.md", SpanMode.depth, false);
  foreach (path; de)
  {
    string content = renderPage(path, &readContents, true);
    rdb.set(path, content);
  }

  // Build downloads page.
  {
    string path = "views/downloads";
    string content = renderPage(path, &renderDownloadsPage, true);
    rdb.set(path, content);
  }

  rc.quit();
}

