package io.netty.channel.uring;

/**
 * Prints what THIS kernel supports, as io_uring's own runtime probes report it - never what the
 * branch's API merely offers.  Declared in netty's own package so that the package-private probes
 * ({@code IORING_SETUP_*}, the kernel version) can be read as well as the public ones.
 *
 * <pre>java -cp &lt;netty cp&gt;:&lt;this class&gt; io.netty.channel.uring.IoUringProbe</pre>
 */
public final class IoUringProbe {
    public static void main(String[] args) {
        System.out.println("kernel=" + Native.kernelVersion());
        try {
            IoUring.ensureAvailability();
            System.out.println("available=true");
        } catch (Throwable t) {
            System.out.println("available=false cause=" + t);
            System.out.println(IoUring.featureString());
            return;
        }
        System.out.println(IoUring.featureString());
        System.out.println("setup flags probed: SUBMIT_ALL=" + IoUring.isSetupSubmitAllSupported()
                + " CQE_MIXED=" + IoUring.isSetupCqeMixedSupported()
                + " CQSIZE=" + IoUring.isSetupCqeSizeSupported()
                + " SINGLE_ISSUER=" + IoUring.isSetupSingleIssuerSupported()
                + " DEFER_TASKRUN=" + IoUring.isSetupDeferTaskrunSupported()
                + " NO_SQARRAY=" + IoUring.isIoringSetupNoSqarraySupported());
        System.out.println("ops probed: SPLICE=" + IoUring.isSpliceSupported()
                + " SEND_ZC=" + IoUring.isSendZcSupported()
                + " SENDMSG_ZC=" + IoUring.isSendmsgZcSupported()
                + " ACCEPT_MULTISHOT=" + IoUring.isAcceptMultishotSupported()
                + " RECV_MULTISHOT=" + IoUring.isRecvMultishotSupported()
                + " POLL_ADD_MULTISHOT=" + IoUring.isPollAddMultishotSupported()
                + " RECVSEND_BUNDLE=" + IoUring.isRecvsendBundleSupported()
                + " REGISTER_BUFFER_RING=" + IoUring.isRegisterBufferRingSupported()
                + " REGISTER_BUFFER_RING_INC=" + IoUring.isRegisterBufferRingIncSupported()
                + " REGISTER_IOWQ_MAX_WORKERS=" + IoUring.isRegisterIowqMaxWorkersSupported()
                + " CQE_F_SOCK_NONEMPTY=" + IoUring.isCqeFSockNonEmptySupported()
                + " ENTER_NO_IOWAIT=" + IoUring.isIoringEnterNoIoWaitSupported());
        System.out.println("enabled by default in this build: ACCEPT_MULTISHOT="
                + IoUring.isAcceptMultishotEnabled()
                + " RECV_MULTISHOT=" + IoUring.isRecvMultishotEnabled()
                + " RECVSEND_BUNDLE=" + IoUring.isRecvsendBundleEnabled()
                + " POLL_ADD_MULTISHOT=" + IoUring.isPollAddMultishotEnabled()
                + " ENTER_NO_IOWAIT=" + IoUring.isIoringEnterNoIoWaitEnabled());
        System.out.println("tcpFastOpenServer=" + IoUring.isTcpFastOpenServerSideAvailable()
                + " tcpFastOpenClient=" + IoUring.isTcpFastOpenClientSideAvailable());
    }
}
