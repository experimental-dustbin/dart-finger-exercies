import 'dart:io';
import 'dart:async';

// sometimes delete does not mean deleted so we have to
// do an extra check when we receive a delete event
Stream<FileSystemEvent> saneEvents(File f) async* {
  await for (final ev in f.watch()) {
    switch (ev.type) {
      case FileSystemEvent.DELETE:
        if (await FileSystemEntity.isFile(ev.path)) {
          break;
        } else {
          yield ev;
        }
        break;
      default:
        yield ev;
    }
  }
}

// Keep the local state of the file we are tracking and allow operations
// to be performed on said file like reading in a non-blocking manner,
// resetting read position, etc.
class Context {

  final String filename;
  final File tailee;
  RandomAccessFile opened;
  int start;
  int recentPosition;

  Context(final String this.filename) : tailee = new File(filename) {
    // what is our initial starting point
    start = tailee.lengthSync();
    opened = tailee.openSync();
    opened.setPosition(start);
    // we need this for verifying file truncation
    recentPosition = start;
  }

  Future<List<int>> read(int size) => opened.read(size);

  get positionMismatch => recentPosition != opened.lengthSync();

  updateRecentPosition() { recentPosition = opened.positionSync(); }

  get position => opened.positionSync();

  set position(int position) { opened.setPositionSync(position); }

}

// watches the events on the file and performs contextual operations
class EventedTailer {

  final Context context;

  EventedTailer(final this.context);

  modificationAction(final FileSystemEvent ev) async {
    if ((ev as FileSystemModifyEvent).contentChanged) {
      List<int> read = await context.read(200);
      // we tried to read but got nothing so maybe truncated
      if (read.length == 0) {
        // if there is a position mismatch then reset position to 0.
        // note: it is possible that the file will be truncated and
        // exactly the right of amount data will be written to overwrite
        // up to the position we are currently at. in this case the length
        // and position will match but we won't know that we need
        // to reset the position. i'm going to assume this is very unlikely
        // because i don't know how to avoid it.
        if (context.positionMismatch) {
          // reset to 0 and retry
          context.position = 0;
          read = await context.read(200);
        }
        // Note: the above logic can fail in an interesting way.
        // write some bytes, write those bytes again
      }
      print('Read: ${read}');
      // continue accumulating into the buffer while possible
      while (read.length > 0) {
        read = await context.read(200);
        print('Read: ${read}');
      }
      context.updateRecentPosition();
      // TODO: transform read buffer
    }
    else { // TODO: content was not modified so what should we do?

    }
  }

  // start listening for file events and performing contextual actions
  start() {
    saneEvents(context.tailee).listen((final FileSystemEvent ev) async {
      print('Event: ${ev}');
      // dispatch on the event type
      switch (ev.type) {
      // can't do anything with a deleted file
        case FileSystemEvent.DELETE:
          return 0;
      // similar to above we just give up and wait to be restarted
        case FileSystemEvent.MOVE:
          return 0;
      // go to beginning
        case FileSystemEvent.CREATE:
          context.position = 0;
          break;
      // file was modified so we should try to read
        case FileSystemEvent.MODIFY:
          modificationAction(ev);
          break;
      // we covered all event cases above so this can't happen
        default:
          throw "unreachable";
      }
      print('Position: ${context.position}');
    });
  }

}

Future main() async {
  String f = 't.log';
  // nothing to do if the file doesn't exist
  if (!FileSystemEntity.isFileSync(f)) {
    return 0;
  }
  // the file we are interested in watching
  final Context context = new Context(f);
  final EventedTailer eventedTailer = new EventedTailer(context);
  eventedTailer.start();
}