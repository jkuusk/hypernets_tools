
from sys import exit

from argparse import ArgumentParser

from hypernets.abstract.request import Request, EntranceExt, RadiometerExt

from hypernets.hypstar.libhypstar.python.hypstar_wrapper import Hypstar, \
    wait_for_instrument

from hypernets.hypstar.libhypstar.python.data_structs.hardware_info import \
    HypstarSupportedBaudRates


class HypstarHandler(Hypstar):
    def __init__(self, instrument_port="/dev/radiometer0",
                 instrument_baudrate=115200, instrument_loglevel=3,
                 expect_boot_packet=True, boot_timeout=30):

        if expect_boot_packet and not wait_for_instrument(instrument_port, boot_timeout): # noqa
            # just in case instrument sent BOOTED packet while we were
            # switching baudrates, let's test if it's there
            try:
                super().__init__(instrument_port)

            except IOError as e:
                print(f"Error : {e}")
                print("[ERROR] Did not get instrument BOOTED packet in {}s".format(boot_timeout)) # noqa
                exit(27)

            except Exception as e:
                print(f"Error : {e}")

        else:  # Got the boot packet or boot packet is not expected (gui mode)
            try:
                super().__init__(instrument_port)

            except Exception as e:
                print(f"Error : {e}")
                exit(6)

        try:
            self.set_log_level(instrument_loglevel)
            self.set_baud_rate(HypstarSupportedBaudRates(instrument_baudrate))
            self.get_hw_info()
            # due to the bug in PSU HW revision 3 12V regulator might not start
            # up properly and optical multiplexer is not available since this
            # prevents any spectra acquisition, instrument is unusable and
            # there's no point in continuing instrument power cycling is the
            # only workaround and that's done in run_sequence bash script so we
            # signal it that it's all bad
            if not self.hw_info.optical_multiplexer_available:
                print("[ERROR] MUX+SWIR+TEC hardware not available")
                exit(27)  # SIGABORT

        except IOError as e:
            print(f"Error : {e}")
            exit(6)

        except Exception as e:
            print(e)
            # if instrument does not respond, there's no point in doing
            # anything, so we exit with ABORTED signal so that shell script can
            # catch exception
            exit(6)  # SIGABRT

    def take_request(self, request, path_to_file=None, gui=False):

        if path_to_file is None:
            from os import path, mkdir
            path_to_file = path.join("DATA", request.spectra_name_convention())

            if not path.exists("DATA"):
                mkdir("DATA")

        if request.entrance == EntranceExt.PICTURE:
            self.take_picture(path_to_file)

        elif request.radiometer != RadiometerExt.NONE:
            self.take_spectra(request, path_to_file)

        return path_to_file

    def take_picture(self, path_to_file, params=None, return_stream=False):
        # Note : 'params = None' for now, only 5MP is working
        try:
            self.packet_count = self.capture_JPEG_image(flip=True)
            if not self.packet_count:
                return False
            stream = self.download_JPEG_image()
            with open(path_to_file, 'wb') as f:
                f.write(stream)

            print(f"Saved to {path_to_file}.")
            if return_stream:
                return stream
            return True

        except Exception as e:
            print(f"Error : {e}")
            return e

    def take_spectra(self, request, path_to_file, env=False,
                     overwrite_IT=True):
        try:
            if env:
                # get latest environmental log and print it to output log
                env_log = self.get_env_log()
                print(env_log.get_csv_line(), flush=True)

            cap_count = self.capture_spectra(request.radiometer,
                                             request.entrance,
                                             request.it_vnir,
                                             request.it_swir,
                                             request.number_cap,
                                             request.total_measurement_time)

            slot_list = self.get_last_capture_spectra_memory_slots(cap_count)
            cap_list = self.download_spectra(slot_list)

            if len(cap_list) == 0:
                return Exception("Cap list length is zero!")

            # Concatenation
            spectra = b''
            for n, spectrum in enumerate(cap_list):
                spectra += spectrum.getBytes()
                print_extra_log = False

                if print_extra_log:
                    print(spectrum)

                if overwrite_IT:
                    if spectrum.spectrum_header.spectrum_config.vnir:
                        request.it_vnir = \
                            spectrum.spectrum_header.integration_time_ms
                    elif spectrum.spectrum_header.spectrum_config.swir:
                        request.it_swir = \
                            spectrum.spectrum_header.integration_time_ms

            # Save
            with open(path_to_file, "wb") as f:
                f.write(spectra)

            print(f"Saved to {path_to_file}.")

        except Exception as e:
            print(f"Error (in take_spectra): {e}")
            return e

        return True

    def get_serials(self):
        try:
            print("Getting SN")  # LOGME
            instrument = self.hw_info.instrument_serial_number
            visible = self.hw_info.vis_serial_number
            swir = self.hw_info.swir_serial_number
            return instrument, visible, swir

        except Exception as e:
            print(f"Error : {e}")
            return e


if __name__ == '__main__':

    parser = ArgumentParser()

    mode = parser.add_mutually_exclusive_group(required=True)

    mode.add_argument("-p", "--picture", action="store_true",
                      help="Take a picture (5MP)")

    mode.add_argument("-r", "--radiometer", type=str,
                      metavar="{vnir, swir, both}",
                      choices=["vnir", "swir", "both"],
                      help="Select a radiometer")

    parser.add_argument("-e", "--entrance", type=str,
                        metavar="{irr, rad, dark}",
                        choices=["irr", "rad", "dark"],
                        help="Select an entrance")

    parser.add_argument("-v", "--it-vnir", type=int, default=0,
                        help="Integration Time for VNIR (default=0)")

    parser.add_argument("-w", "--it-swir", type=int, default=0,
                        help="Integration Time for SWIR (default=0)")

    parser.add_argument("-n", "--count", type=int, default=1,
                        help="Number of capture (default=1)")

    parser.add_argument("-o", "--output", type=str, default=None,
                        help="Specify output file name")

    args = parser.parse_args()

    if args.radiometer and not args.entrance:
        parser.error(f"Please select an entrance for the {args.radiometer}.")

    if args.entrance and not args.radiometer:
        parser.error(f"Please select a radiometer for {args.entrance}.")

    # TODO : more args for hypstar options ? (i.e. : baudate, etc..)
    instrument_instance = HypstarHandler(expect_boot_packet=False)

    if args.picture:
        instrument_instance.take_picture()
        exit(0)

    measurement = args.radiometer, args.entrance, args.it_vnir, args.it_swir
    request = Request.from_params(args.count, *measurement)
    instrument_instance.take_spectra(request)