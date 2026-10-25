"""rtw88 USB: resubmit RX URBs after transient bus errors.

rtw_usb_read_port_complete() only resubmits an RX URB that completed without error. On a transient
error (-EPROTO, -EILSEQ, -ETIME, -ECOMM, -EOVERFLOW: a glitch on the bus) it returns the buffer to
the free queue and stops there: the URB is never sent again, and since rxcb->rx_skb still points
at the returned buffer, rtw_usb_rx_resubmit_work() skips it too. With RTW_USB_RXCB_NUM (4) URBs,
four such glitches and the device receives nothing more until the interface is reset.

On this box (RTL8812BU on a BCM7231 EHCI) it shows as a slow loss of the access point's beacons
(4 URBs, then 3, 2, 1: fewer and fewer frames get through) ending in total silence, beacon loss
and an unreachable gateway until wifi-watch restarts WiFi; a monitor interface, which multiplies
the RX traffic and so the glitches, brought it on within the hour.

Fix: resubmit on transient errors (rate-limited warning, to see them happen); on fatal ones (the
URB killed, the device gone) do not, but release the control block so that nothing keeps pointing
at a buffer back in the free queue.
"""

from pathlib import Path

path = Path("drivers/net/wireless/realtek/rtw88/usb.c")
src = path.read_text()

MARK = "AirTies-: resubmit RX URB after transient error"
if MARK in src:
    raise SystemExit(0)

old = """	} else {
		skb_queue_tail(&rtwusb->rx_free_queue, skb);

		switch (urb->status) {
		case -EINVAL:
		case -EPIPE:
		case -ENODEV:
		case -ESHUTDOWN:
		case -ENOENT:
		case -EPROTO:
		case -EILSEQ:
		case -ETIME:
		case -ECOMM:
		case -EOVERFLOW:
		case -EINPROGRESS:
			break;
		default:
			rtw_err(rtwdev, "status %d\\n", urb->status);
			break;
		}
	}"""

new = """	} else {
		skb_queue_tail(&rtwusb->rx_free_queue, skb);

		switch (urb->status) {
		case -EPROTO:
		case -EILSEQ:
		case -ETIME:
		case -ECOMM:
		case -EOVERFLOW:
			/* AirTies-: resubmit RX URB after transient error: otherwise each glitch
			 * on the bus loses one of the RTW_USB_RXCB_NUM URBs for good, and after a
			 * few of them nothing is received any more
			 */
			dev_warn_ratelimited(rtwdev->dev, "rx urb status %d, resubmitting\\n",
					     urb->status);
			rtw_usb_rx_resubmit(rtwusb, rxcb, GFP_ATOMIC);
			break;
		case -EINVAL:
		case -EPIPE:
		case -ENODEV:
		case -ESHUTDOWN:
		case -ENOENT:
		case -EINPROGRESS:
			rxcb->rx_skb = NULL;
			break;
		default:
			rtw_err(rtwdev, "status %d\\n", urb->status);
			rxcb->rx_skb = NULL;
			break;
		}
	}"""

if old not in src:
    raise SystemExit("rtw88 usb.c: RX completion anchor not found (driver changed in this kernel?)")
path.write_text(src.replace(old, new, 1))
print("[*] rtw88 usb.c: RX URBs resubmitted after transient errors")
