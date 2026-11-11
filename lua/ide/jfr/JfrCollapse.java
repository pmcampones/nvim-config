// Converts a Java Flight Recorder recording into "collapsed stacks" (one line per distinct
// stack: "root;caller;...;leaf <samples>"), the usual input for flame graphs
// (flamegraph.pl, speedscope, inferno, and the Neovim viewer in lua/ide/flamegraph.lua).
//
// Usage: java JfrCollapse.java <recording.jfr> <output.collapsed.txt>
// Only CPU samples (jdk.ExecutionSample) are used. Each stack starts with the thread name
// in brackets, e.g. "[main];java.lang.Thread.run;...".

import java.io.BufferedWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordedFrame;
import jdk.jfr.consumer.RecordedMethod;
import jdk.jfr.consumer.RecordedStackTrace;
import jdk.jfr.consumer.RecordedThread;
import jdk.jfr.consumer.RecordingFile;

public class JfrCollapse {
  public static void main(String[] args) throws Exception {
    Map<String, Long> counts = new HashMap<>();
    long samples = 0;
    try (RecordingFile recording = new RecordingFile(Path.of(args[0]))) {
      while (recording.hasMoreEvents()) {
        RecordedEvent event = recording.readEvent();
        if (!event.getEventType().getName().equals("jdk.ExecutionSample")) {
          continue;
        }
        RecordedStackTrace stack = event.getStackTrace();
        if (stack == null) {
          continue;
        }
        StringBuilder line = new StringBuilder();
        RecordedThread thread = event.getThread("sampledThread");
        line.append('[').append(clean(thread != null && thread.getJavaName() != null ? thread.getJavaName() : "thread")).append(']');
        List<RecordedFrame> frames = stack.getFrames();
        for (int i = frames.size() - 1; i >= 0; i--) { // JFR lists the leaf first
          RecordedMethod method = frames.get(i).getMethod();
          if (method == null) {
            continue;
          }
          line.append(';').append(clean(method.getType().getName())).append('.').append(clean(method.getName()));
        }
        counts.merge(line.toString(), 1L, Long::sum);
        samples++;
      }
    }
    try (BufferedWriter out = Files.newBufferedWriter(Path.of(args[1]))) {
      for (Map.Entry<String, Long> e : counts.entrySet()) {
        out.write(e.getKey());
        out.write(' ');
        out.write(Long.toString(e.getValue()));
        out.newLine();
      }
    }
    System.out.println(samples + " samples, " + counts.size() + " distinct stacks");
  }

  // ';' separates frames and the last ' ' separates the count: keep them out of names
  private static String clean(String s) {
    return s.replace(';', ':').replace(' ', '_');
  }
}
