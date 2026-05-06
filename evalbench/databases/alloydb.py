
from .db import DB
from .postgres import PGDB
import sqlalchemy
from sqlalchemy.pool import NullPool
from google.cloud.alloydb.connector import Connector as AlloyDBConnector
from google.cloud.alloydb.connector import IPTypes as AlloyDBIPTypes

CONNECTOR = AlloyDBConnector()


class AlloyDB(PGDB):
    def __init__(self, db_config):
        """
        Initializes the AlloyDB connection, overriding the PGDB's
        default Google Cloud SQL connection mechanism.
        """
        super().__init__(db_config)
        self.nl_config = db_config['nl_config']

        if 'api_endpoint' in db_config:
            CONNECTOR._alloydb_api_endpoint = db_config['api_endpoint']

        def get_conn_alloydb():
            import logging
            logging.info(f"AlloyDB connecting with password is None? {self.password is None}")
            
            # Strip the suffix for service accounts as required by IAM auth
            # db_user = self.username
            # if db_user and db_user.endswith(".gserviceaccount.com"):
            #     db_user = db_user.replace(".gserviceaccount.com", "")
            #     logging.info(f"Stripped .gserviceaccount.com suffix. Using user: {db_user}")
            logging.info(f"Use ADC: {self.use_adc} for user: {self.username}")   
            return CONNECTOR.connect(
                self.db_path,
                "pg8000",
                user=self.username,
                password=self.password if self.password is not None else "",
                db=self.db_name,
                enable_iam_auth=self.use_adc,  # handled in PGDB
                ip_type=AlloyDBIPTypes.PUBLIC,
            )

        def get_engine_args_alloydb():
            common_args = {
                "creator": get_conn_alloydb,
                "connect_args": {"command_timeout": 60},
            }
            if "is_tmp_db" in db_config:
                common_args["poolclass"] = NullPool
            else:
                common_args["pool_size"] = 50
                common_args["pool_recycle"] = 300
            return common_args

        self.engine = sqlalchemy.create_engine(
            "postgresql+pg8000://", **get_engine_args_alloydb()
        )
