import jdk.jfr.consumer.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;

/** Dump AllocateBuffer/FreeBuffer/IterationEnd to TSV with nanosecond timestamps.
 *  `jfr print` truncates startTime to milliseconds, which cannot order 450k events/s. */
public final class Dump {
    static boolean skip(String cls) {
        if (cls.equals("io.netty.util.ReferenceCountUtil")) return true;
        if (!cls.startsWith("io.netty.buffer.")) return false;
        String s = cls.substring("io.netty.buffer.".length());
        return !s.startsWith("CompositeByteBuf");
    }
    public static void main(String[] a) throws Exception {
        try (RecordingFile rf = new RecordingFile(Paths.get(a[0]));
             PrintWriter w = new PrintWriter(new BufferedWriter(new FileWriter(a[1]), 1 << 20))) {
            w.println("#ns\tkind\tthread\taddress\tsize\treads\ttrunc\tsites");
            long i = 0;
            while (rf.hasMoreEvents()) {
                RecordedEvent e = rf.readEvent();
                String n = e.getEventType().getName();
                char k;
                if (n.equals("io.netty.AllocateBuffer")) k = 'A';
                else if (n.equals("io.netty.FreeBuffer")) k = 'F';
                else if (n.equals("io.netty.ReallocateBuffer")) k = 'R';
                else if (n.equals("netty.IterationEnd")) k = 'I';
                else continue;
                java.time.Instant t = e.getStartTime();
                long ns = t.getEpochSecond() * 1_000_000_000L + t.getNano();
                RecordedThread th = e.getThread();
                String tn = th == null ? "?" : th.getJavaName();
                long addr = (k == 'I') ? 0 : e.getLong("address");
                int sz = (k == 'I') ? 0 : e.getInt("size");
                int rd = (k == 'I') ? e.getInt("reads") : 0;
                String sites = "";
                int trunc = 0;
                if (k == 'F') {
                    RecordedStackTrace st = e.getStackTrace();
                    if (st != null) {
                        trunc = st.isTruncated() ? 1 : 0;
                        StringBuilder sb = new StringBuilder();
                        int kept = 0;
                        for (RecordedFrame f : st.getFrames()) {
                            RecordedMethod m = f.getMethod();
                            String cls = m.getType().getName();
                            if (skip(cls)) continue;
                            if (kept++ > 0) sb.append('|');
                            sb.append(cls).append('.').append(m.getName());
                            if (kept == 10) break;
                        }
                        sites = sb.toString();
                    }
                }
                w.print(ns); w.print('\t'); w.print(k); w.print('\t'); w.print(tn); w.print('\t');
                w.print(addr); w.print('\t'); w.print(sz); w.print('\t'); w.print(rd); w.print('\t');
                w.print(trunc); w.print('\t'); w.println(sites);
                i++;
            }
            System.err.println("dumped " + i + " events -> " + a[1]);
        }
    }
}
