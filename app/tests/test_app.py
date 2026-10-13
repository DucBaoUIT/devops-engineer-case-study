import os,sys,unittest
sys.path.insert(0,os.path.dirname(os.path.dirname(__file__)))
from app import app
class AppTests(unittest.TestCase):
 def setUp(self): self.client=app.test_client()
 def test_health(self): self.assertEqual(self.client.get("/health").status_code,200)
 def test_home(self): self.assertEqual(self.client.get("/").get_json()["service"],"demo-web")
if __name__=="__main__": unittest.main()
