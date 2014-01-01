#cython: embedsignature=True
include "definitions.pxi"
from pcap cimport *
from cpython cimport bool, PyErr_Occurred
import os, sys

cdef PCAP_LOOP_DISPATCH = 0
cdef PCAP_LOOP_LOOP = 1

class PcapError(Exception):
    pass

class PcapErrorBreak(Exception):
    pass

class PcapErrorNotActivated(Exception):
    pass

class PcapErrorActivated(Exception):
    pass

class PcapErrorNoSuchDevice(Exception):
    pass

class PcapErrorRfmonNotSup(Exception):
    pass

class PcapErrorNotRfmon(Exception):
    pass

class PcapErrorPermDenied(Exception):
    pass

class PcapErrorIfaceNotUp(Exception):
    pass

class PcapWarning(Exception):
    pass

class PcapWarningPromiscNotSup(Exception):
    pass

class PcapTimeout(Exception):
    pass

cdef void __pcap_callback_fn(unsigned char *user, const_pcap_pkthdr_ptr pkthdr, const_uchar_ptr pktdata) except *:
    cdef pcap_callback_ctx *ctx = <pcap_callback_ctx *>user
    cdef PcapPacket pkt = PcapPacket_factory(pkthdr, pktdata)
    cdef Pcap pcap = <object>ctx.pcap
    cdef args = <object>ctx.args
    cdef kwargs = <object>ctx.kwargs
    cdef callback = <object>ctx.callback

    if PyErr_Occurred():
        pcap.breakloop()

    if callback:
        callback(pkt, *args, **kwargs)
    if pcap.__dumper:
        pcap.__dumper.dump(pkt)

cdef class PcapDumper

cdef class BpfProgram

# Things that work with all pcap_t
cdef class Pcap(object):
    """Generic Pcap object. Instantiate via PcapLive or PcapOffline"""
    cdef pcap_t *__pcap
    cdef PcapDumper __dumper
    cdef BpfProgram __filter
    cdef __autosave
    cdef bool __activated
    def __init__(self):
        raise TypeError("Instantiate a PcapLive of PcapOffline class")

    def __iter__(self):
        return self

    def __next__(self):
        """Get the next available PcapPacket"""
        cdef PcapPacket pkt
        cdef pcap_pkthdr *hdr
        cdef const_uchar_ptr data

        if not self.activated:
            raise PcapErrorNotActivated()

        res = pcap_next_ex(self.__pcap, &hdr, &data)
        if res == 0:
            raise PcapTimeout()
        if res == -1:
            raise PcapError(pcap_geterr(self.__pcap))
        if res == -2:
            raise StopIteration
        IF not PCAP_V0:
            if res == PCAP_ERROR_NOT_ACTIVATED:
                raise PcapErrorNotActivated() # This is undocumented, but happens
        if res == 1:
            pkt = PcapPacket_factory(hdr, data)
            if self.__dumper:
                self.__dumper.dump(pkt)
            return pkt
        else:
            raise PcapError("Unknown error")

    cdef __loop_common(self, looptype, count, callback, args, kwargs):
        cdef pcap_callback_ctx ctx

        if not self.activated:
            raise PcapErrorNotActivated()

        ctx.callback = <void *>callback
        ctx.args = <void *>args
        ctx.kwargs = <void *>kwargs
        ctx.pcap = <void *>self
        if looptype == PCAP_LOOP_DISPATCH:
            res = pcap_dispatch(self.__pcap, count, __pcap_callback_fn, <unsigned char *>&ctx)
        else:
            res = pcap_loop(self.__pcap, count, __pcap_callback_fn, <unsigned char *>&ctx)

        # An exception occurred while looping. pcap_loop won't return on an exception, so to get
        # the exception that really happened instead of a PcapErrorBreak, we need to look it up
        err = <object>PyErr_Occurred()
        if err:
            raise sys.exc_info()

        if res >= 0:
            if looptype == PCAP_LOOP_DISPATCH:
                return res
            else:
                return None
        if res == -1:
            raise PcapError(pcap_geterr(self.__pcap))
        if res == -2:
            raise PcapErrorBreak()
        IF not PCAP_V0:
            if res == PCAP_ERROR_NOT_ACTIVATED:
                raise PcapErrorNotActivated()
        raise PcapError("Unknown error")

    def dispatch(self, count, callback, *args, **kwargs):
        """Process packets from a live capture or savefile

        Args:
            count (int): The maximum number of packets to return

            callback (function): A callback function accepting a PcapPacket, and optional args and kwargs

        Returns:
            int.  The number of packets returned

        Raises:
            PcapErrorNotActivated, PcapError, PcapErrorBreak

        """
        return self.__loop_common(PCAP_LOOP_DISPATCH, count, callback, args, kwargs)

    def loop(self, count, callback, *args, **kwargs):
        """Process packets from a live capture or savefile

        Args:
            count (int): The maximum number of packets to return

            callback (function): A callback function accepting a PcapPacket, and optional args and kwargs

        Raises:
            PcapErrorNotActivated, PcapError, PcapErrorBreak
        """
        return self.__loop_common(PCAP_LOOP_LOOP, count, callback, args, kwargs)

    def breakloop(self):
        """Set a flag that will force dispatch or loop to raise PcapErrorBreak rather than looping"""

        if not self.activated:
            return PcapErrorNotActivated()
        pcap_breakloop(self.__pcap)

    # It sucks that this requires an activated pcap since it means
    # that we will capture non-matching packets between activation
    # and calling setfilter()
    property filter:
        """Filter packets through a Berkeley Packet Filter (read/write)

        The filter can be set either with a string describing a BPF filter,
        e.g. "port 80", or with a BpfProgram instance

        Raises:
            PcapError, PcapErrorNotActivated

        """
        def __get__(self):
            return self.__filter
        def __set__(self, bpf):
            if not self.activated:
                raise PcapErrorNotActivated()
            if isinstance(bpf, BpfProgram):
                self.__filter = bpf
            elif isinstance(bpf, basestring):
                self.__filter = BpfProgram(self, bpf)
            else:
                raise TypeError("Must pass a BpfProgram or string type")
            res = pcap_setfilter(self.__pcap, &self.__filter.__bpf)
            if res == -1:
                raise PcapError(pcap_geterr(self.__pcap))
            IF not PCAP_V0:
                if res == PCAP_ERROR_NOT_ACTIVATED:
                    raise PcapErrorNotActivated()

    property datalink:
        """String representation of the datalink, i.e. 'EN10MB' (read-only)

        Raises:
            PcapError, PcapErrorNotActivated

        """
        def __get__(self):
            if not self.activated:
                raise PcapErrorNotActivated()
            # libpcap currently returns no error if the pcap isn't
            # isn't yet active.
            return pcap_datalink_val_to_name(pcap_datalink(self.__pcap))

    property activated:
        """Whether or not the capture has been activated (read/write)"""
        def __get__(self):
            return self.__activated

    def __dealloc__(self):
        if self.__pcap:
            pcap_close(self.__pcap)


# Things that work with pcap_open_live/pcap_create
cdef class PcapLive(Pcap):
    cdef __snaplen
    cdef __promisc
    cdef __rfmon
    cdef __timeout
    cdef __buffer_size
    cdef __interface
    def __init__(self, interface, snaplen=65535, promisc=False, rfmon=False,
            timeout=0, buffer_size=0, autosave=None):
        """Pcap object for a live capture

        Args:
            interface (str): The interface name

        Kwargs:
            snaplen (int): How many bytes of each packet to capture

            promisc (bool): Whether or not to capture in promiscuous mode

            timeout (int): The maximum time to wait for a packet. A value of 0 means no
                           timeout. On some platforms this results in waiting until a
                           sufficient number of packets are buffered before returning,
                           therefor it is almost always advisable to set a timeout.

            autosave (str): The filename to pass to a PcapDumper object that will be used
                            to save any packet that is processed with dispatch() or next().

            rfmon (bool): Whether or not to enable radio frequency monitor mode

            buffer_size (int): Override the default pcap buffer size. This option should
                               rarely be needed.

        Raises:
            PcapError, PcapErrorActivated

        """
        cdef char errbuf[PCAP_ERRBUF_SIZE]
        self.__interface = interface # For now, eventually we'll look it up and do PcapInterface
        self.__activated = False
        if not PCAP_V0:
            self.__pcap = pcap_create(self.__interface, errbuf)
            if self.__pcap is NULL:
                raise PcapError(errbuf)

        # Set default values via properties
        self.snaplen = snaplen
        self.promisc = promisc
        self.timeout = timeout
        self.__autosave = autosave

        IF not PCAP_V0:
            self.rfmon = rfmon
            self.buffer_size = buffer_size

    property interface:
        """The name of the capture interface (read-only)"""
        def __get__(self):
            return self.__interface

    property snaplen:
        """The number of bytes of each captured packet to store (read/write)

        Raises:
            PcapErrorActivated

        """
        def __get__(self):
            return self.__snaplen
        def __set__(self, snaplen):
            IF PCAP_V0:
                if self.__pcap:
                    raise PcapErrorActivated()
            ELSE:
                if pcap_set_snaplen(self.__pcap, snaplen) == PCAP_ERROR_ACTIVATED:
                    raise PcapErrorActivated()
            self.__snaplen = snaplen

    property promisc:
        """Whether or not to capture in promiscuous mode (read/write)

        Raises:
            PcapErrorActivated

        """
        def __get__(self):
            return self.__promisc
        def __set__(self, promisc):
            IF PCAP_V0:
                if self.__pcap:
                    raise PcapErrorActivated()
            ELSE:
                if pcap_set_promisc(self.__pcap, promisc) == PCAP_ERROR_ACTIVATED:
                    raise PcapErrorActivated()
            self.__promisc = promisc

    property timeout:
        """The timeout for receiving packets with next() and dispatch() (read/write)

        Raises:
            PcapErrorActivated

        """
        def __get__(self):
            return self.__timeout
        def __set__(self, timeout):
            IF PCAP_V0:
                if self.__pcap:
                    raise PcapErrorActivated()
            ELSE:
                if pcap_set_timeout(self.__pcap, timeout) == PCAP_ERROR_ACTIVATED:
                    raise PcapErrorActivated()
            self.__timeout = timeout

    property rfmon:
        """Whether or not to turn on radio frequency monitor mode (read/write)

        Raises:
            PcapErrorActivated, PcapErrorNoSuchDevice, PcapError

        """
        def __get__(self):
            IF PCAP_V0:
                raise PcapError("%s is too old for this call" % (lib_version(),))
            ELSE:
                return self.__rfmon
        def __set__(self, rfmon):
            IF PCAP_V0:
                raise PcapError("%s is too old for this call" % (lib_version(),))
            ELSE:
                res = pcap_can_set_rfmon(self.__pcap)
                if res == 0:
                    # Could not set rfmon for some non-error reason
                    return
                elif res == PCAP_ERROR_NO_SUCH_DEVICE:
                    raise PcapErrorNoSuchDevice()
                elif res == PCAP_ERROR_ACTIVATED:
                    raise PcapErrorActivated()
                elif res == PCAP_ERROR:
                    raise PcapError(pcap_geterr(self.__pcap))
                elif res == 1:
                    if pcap_set_rfmon(self.__pcap, rfmon) == PCAP_ERROR_ACTIVATED:
                        raise PCAP_ERROR_ACTIVATED
                    self.__rfmon = rfmon

    property buffer_size:
        """If overidden from the default, the number of bytes to allocate for the
        pcap buffer (read/write)

        Raises:
            PcapError, PcapErrorActivated

        """
        def __get__(self):
            IF PCAP_V0:
                raise PcapError("%s is too old for this call" % (lib_version(),))
            ELSE:
                return self.__buffer_size
        def __set__(self, timeout):
            IF PCAP_V0:
                raise PcapError("%s is too old for this call" % (lib_version(),))
            ELSE:
                if pcap_set_buffer_size(self.__pcap, timeout) == PCAP_ERROR_ACTIVATED:
                    raise PcapErrorActivated()

    property fileno:
        """The underlying file descriptor for the capture (read-only)

        Raises:
            PcapError, PcapErrorNotActivated

        """
        def __get__(self):
            res = pcap_fileno(self.__pcap)
            if res == -1:
                # With a live file capture, this should only happen when not activated
                raise PcapErrorNotActivated()
            return res

    # Reverse the logic from checking the negative: nonblock
    property blocking:
        """Whether or not calls to next() or dispatch() should block (read/write)

        Raises:
            PcapError, PcapErrorNotActivated

        """
        def __get__(self):
            cdef char errbuf[PCAP_ERRBUF_SIZE]

            if not self.activated:
                raise PcapErrorNotActivated()

            res = pcap_getnonblock(self.__pcap, errbuf)
            if res == -1:
                raise PcapError(errbuf)
            elif res == 0:
                return True
            elif res == 1:
                return False
            else:
                return PcapError("Unknown error")

        def __set__(self, blocking):
            cdef char errbuf[PCAP_ERRBUF_SIZE]

            if not self.activated:
                raise PcapErrorNotActivated()

            res = pcap_setnonblock(self.__pcap, not blocking, errbuf)
            if res == -1:
                raise PcapError(errbuf)
            IF not PCAP_V0:
                if res == PCAP_ERROR_NOT_ACTIVATED:
                    raise PcapErrorNotActivated() # Not documented, but happens
            if res != 0:
                raise PcapError("Unknown error %d" % (res,))

    def activate(self):
        """Activate the capture and start collecting packets

        Raises:
            PcapError, PcapErrorActivated

        """
        cdef res
        IF PCAP_V0:
            cdef char errbuf[PCAP_ERRBUF_SIZE]

            if self.activated:
                raise PcapErrorActivated()

            self.__pcap = self.__pcap = pcap_open_live(self.__interface, self.__snaplen, self.__promisc, self.__timeout, errbuf)
            if self.__pcap is NULL:
                raise PcapError(errbuf)
            self.__activated = True
        ELSE:
            res = pcap_activate(self.__pcap)
            if res == 0:
                self.__activated = True
                pass
            elif res == PCAP_WARNING_PROMISC_NOTSUP:
                raise PcapWarningPromiscNotSup(pcap_geterr(self.__pcap))
            elif res == PCAP_WARNING:
                raise PcapWarning(pcap_geterr(self.__pcap))
            elif res == PCAP_ERROR_ACTIVATED:
                raise PcapErrorActivated()
            elif res == PCAP_ERROR_NO_SUCH_DEVICE:
                raise PcapErrorNoSuchDevice(pcap_geterr(self.__pcap))
            elif res == PCAP_ERROR_PERM_DENIED:
                raise PcapErrorPermDenied(pcap_geterr(self.__pcap))
            elif res == PCAP_ERROR_RFMON_NOTSUP:
                raise PcapErrorRfmonNotSup()
            elif res == PCAP_ERROR_IFACE_NOT_UP:
                raise PcapErrorIfaceNotUp()
            elif res == PCAP_ERROR:
                raise PcapError(pcap_geterr(self.__pcap))

        if self.__autosave:
            self.__dumper = PcapDumper(self, self.__autosave)


# Things that work with pcap_open_offline
cdef class PcapOffline(Pcap):
    cdef __filename
    def __init__(self, filename, autosave=None):
        """Pcap object for reading from a capture file.

        Args:
            filename (str): The filename of the capture file to process
            
        Kwargs:
            autosave (str): The filename to pass to a PcapDumper object that will be used
                            to save any packet that is processed with dispatch() or next().

        Raises:
            PcapError

        """
        cdef char errbuf[PCAP_ERRBUF_SIZE]
        self.__filename = filename
        self.__autosave = autosave
        self.__activated = False
        self.__pcap = pcap_open_offline(self.__filename, errbuf)
        if self.__pcap == NULL:
            raise PcapError(errbuf)
        self.__activated = True
        if self.__autosave:
            self.__dumper = PcapDumper(self, self.__autosave)

    property filename:
        """The filename of the capture file being processed (read-only)"""
        def __get__(self):
            return self.__filename
    property snaplen:
        """The number of bytes of each captured packet to store (read-only)"""
        def __get__(self):
            return pcap_snapshot(self.__pcap)
    property swapped:
        """Whether the savefile uses a different byte order than the current system (read-only)"""
        def __get__(self):
            return pcap_is_swapped(self.__pcap)
    property major_version:
        """The marjor version of the savefile format (read-only)"""
        def __get__(self):
            return pcap_major_version(self.__pcap)
    property minor_version:
        """The minor version of the savefile format (read-only)"""
        def __get__(self):
            return pcap_minor_version(self.__pcap)

cdef class PcapPacket:
    """A captured packet"""
    cdef pcap_pkthdr __pkthdr
    cdef bytes __data
    def __init__(self):
        raise TypeError("This class cannot be instantiated from Python")

    property timestamp:
        def __get__(self):
            return self.__pkthdr.ts.tv_sec + (<double>self.__pkthdr.ts.tv_usec / 1000000)
    property caplen:
        def __get__(self):
            return self.__pkthdr.caplen
    property wirelen:
        def __get__(self):
            return self.__pkthdr.len
    property data:
        def __get__(self):
            return self.__data

    def __str__(self):
        return "<Packet recived at %f with length %d/%d>" % (self.timestamp, self.wirelen, self.caplen)


cdef PcapPacket PcapPacket_factory(const_pcap_pkthdr_ptr pkt_header, const_uchar_ptr data):
    cdef PcapPacket instance = PcapPacket.__new__(PcapPacket)
    cdef char *cast_data = <char *>data
    instance.__pkthdr = pkt_header[0]
    instance.__data = cast_data[:pkt_header.caplen]
    return instance


cdef class PcapDumper:
    """Saves PcapPackets to a file"""
    cdef pcap_dumper_t *__dumper

    def __init__(self, Pcap pcap, filename):
        self.__dumper = pcap_dump_open(pcap.__pcap, filename)
        if self.__dumper is NULL:
            raise PcapError(pcap_geterr(pcap.__pcap))

    def dump(self, PcapPacket pkt):
        pcap_dump(<unsigned char *>self.__dumper, <pcap_pkthdr *>&pkt.__pkthdr, <unsigned char *>pkt.data)

    def __dealloc__(self):
        pcap_dump_close(self.__dumper)

# Read only cdef factory-created
cdef class PcapInterface:
    """An interface available to libpcap"""
    cdef list __addresses
    cdef bytes __name
    cdef bytes __description
    cdef bool __loopback
    def __init__(self):
        """This class is only returned by yappcap.findalldevs() and cannot be
        instantiated from Python"""
        raise TypeError("Instances of this class cannot be created from Python")

    property name:
        """The interface name, i.e. 'eth0'. (read only)"""
        def __get__(self):
            return self.__name
    property description:
        """A textual description of the interface, if available. (read only)"""
        def __get__(self):
            return self.__description
    property loopback:
        """Whether or not the interface is a loopback interface. (read only)"""
        def __get__(self):
            return self.__loopback
    property addresses:
        """A PcapAddress list for all interfaces assigned to the PcapInterface (read only)"""
        def __get__(self):
            return self.__addresses
    def __str__(self):
        return self.name

cdef PcapInterface PcapInterface_factory(pcap_if_t *interface):
    cdef PcapInterface instance = PcapInterface.__new__(PcapInterface)
    cdef pcap_addr_t *it = interface.addresses
    instance.__addresses = list()
    if interface.name:
        instance.__name = interface.name
    if interface.description:
        instance.__description = interface.description
    if interface.flags & PCAP_IF_LOOPBACK:
        instance.__loopback = True
    else:
        instance.__loopback = False

    while it:
        addr = PcapAddress_factory(it)
        instance.__addresses.append(addr)
        it = it.next
    return instance

cdef str type2str(int t):
    if t == AF_INET:
        return "IPv4"
    if t == AF_INET6:
        return "IPv6"
    IF HAVE_AF_PACKET:
        if t == AF_PACKET:
            return "Packet"
    IF HAVE_AF_LINK:
        if t == AF_LINK:
            return "Link"
    return str(t)

# Read only cdef factory-created
cdef class PcapAddress:
    """An address assigned to a PcapInterface"""
    cdef dict __addr, __netmask, __broadaddr, __dstaddr
    def __init__(self):
        raise TypeError("Instances of this class cannot be created from Python")
    property address:
        """A dict containing the 'family', and if it exists, the 'address'
        of the PcapInterface address"""
        def __get__(self):
            return self.__addr
    property netmask:
        """If applicable, a dict containing the 'family', and if it exists,
        the 'address' of the PcapInterface netmask address"""
        def __get__(self):
            return self.__netmask
    property broadcast:
        """If applicable, a dict containing the 'family', and if it exists,
        the 'address' of the PcapInterface broadcast address"""
        def __get__(self):
            return self.__broadaddr
    property dstaddr:
        """If applicable, a dict containing the 'family', and if it exists,
        the 'address' of the PcapInterface destination address"""
        def __get__(self):
            return self.__dstaddr

    def __str__(self):
        addr = family = nm = None
        if not self.address:
            addr = family = 'Unknown'
        if not self.netmask:
            nm = 'Unknown'

        return "%s: %s/%s" % (family or type2str(self.address['family']), addr or self.address.get('address', 'Unknown'), nm or self.netmask.get('address', 'Unknown'))


cdef get_sock_len(sockaddr *addr):
    if addr.sa_family == AF_INET:
        return sizeof(sockaddr_in)
    if addr.sa_family == AF_INET6:
        return sizeof(sockaddr_in6)
    IF HAVE_AF_PACKET:
        if addr.sa_family == AF_PACKET:
            return sizeof(sockaddr_ll)
    IF HAVE_AF_LINK:
        if addr.sa_family == AF_LINK:
            return sizeof(sockaddr_dl)
    return -1

cdef parse_addr(sockaddr *addr):
    cdef int socklen
    cdef char buf[NI_MAXHOST]

    if not addr:
        return

    socklen = get_sock_len(addr)
    if socklen < 0:
        return {'family': addr.sa_family}
    res = getnameinfo(addr, socklen, buf, sizeof(buf), NULL, 0, NI_NUMERICHOST)
    if res:
        return {'family': addr.sa_family}

    return {'family': addr.sa_family, 'address': buf}

cdef PcapAddress PcapAddress_factory(pcap_addr_t *address):
    cdef PcapAddress instance = PcapAddress.__new__(PcapAddress)
    instance.__addr = parse_addr(address.addr)
    instance.__netmask = parse_addr(address.netmask)
    instance.__broadaddr = parse_addr(address.broadaddr)
    instance.__dstaddr = parse_addr(address.dstaddr)
    return instance

cdef class BpfProgram:
    cdef bpf_program __bpf
    cdef __filterstring
    def __init__(self, Pcap pcap, filterstring):
        """A compiled Berkeley Packet Filter program

        Args:
            pcap (Pcap): An active Pcap instance

            filterstring (str): A string describing a Berkeley Packet Filter

        Raises:
            PcapError, PacapErrorNotActivated

        """
        if not pcap.activated:
            raise PcapErrorNotActivated()
        self.__filterstring = filterstring
        res = pcap_compile(pcap.__pcap, &self.__bpf, filterstring, 1, PCAP_NETMASK_UNKNOWN)
        if res == -1:
            raise PcapError(pcap_geterr(pcap.__pcap))
        IF not PCAP_V0:
            # It should return this, but might not
            if res == PCAP_ERROR_NOT_ACTIVATED:
                raise PcapErrorNotActivated()

    def __str__(self):
        return self.__filterstring


def lib_version():
    """Return the version string from pcap_lib_version()"""
    return pcap_lib_version()

def findalldevs():
    """Return a list of available PcapInterfaces"""
    cdef pcap_if_t *interfaces, *it
    cdef char errbuf[PCAP_ERRBUF_SIZE]
    cdef int res = pcap_findalldevs(&interfaces, errbuf)
    cdef list result = list()
    if res < 0:
        raise PcapError(errbuf)
    it = interfaces
    while it:
        i = PcapInterface_factory(it)
        result.append(i)
        it = it.next
    pcap_freealldevs(interfaces)

    return result

#def lookupdev():
#    """Return a single available PcapInterface"""
#    pass
#
#def lookupnet(ifname):
#    """Return the IPv4 address and netmask of an interface"""
#    pass
