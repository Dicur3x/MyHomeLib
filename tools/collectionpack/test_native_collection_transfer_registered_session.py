"""External reference changes remain visible with transactional registry writes."""
import test_native_collection_transfer_publication_session as publication_fixture


class TransferRegisteredSessionTests(publication_fixture.TransferPublicationSessionTests):
    def setUp(self):
        super().setUp()
        self.config.update(register_operation=True,register_groups=True)
