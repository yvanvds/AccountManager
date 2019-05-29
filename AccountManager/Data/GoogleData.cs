using AbstractAccountApi;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public sealed partial class Data
    {
        const string googleAccountsFile = "googleAccounts.json";

        private void loadGoogleConfig(JObject obj)
        {
            googleAppName = obj.ContainsKey("appName") ? obj["appName"].ToString() : "";
            googleAppDomain = obj.ContainsKey("appDomain") ? obj["appDomain"].ToString() : "";
            googleAdmin = obj.ContainsKey("admin") ? obj["admin"].ToString() : "";
            googleApiKey = obj.ContainsKey("apiKey") ? obj["apiKey"].ToString() : "";
            googleApiID = obj.ContainsKey("apiID") ? obj["apiID"].ToString() : "";
            googleApiToken = obj.ContainsKey("apiToken") ? obj["apiToken"].ToString() : "";
        }

        private JObject saveGoogleConfig()
        {
            JObject result = new JObject();
            result["appName"] = googleAppName;
            result["appDomain"] = googleAppDomain;
            result["admin"] = googleAdmin;
            result["apiKey"] = googleApiKey;
            result["apiID"] = googleApiID;
            result["apiToken"] = googleApiToken;
            return result;
        }

        private void loadGoogleFileContent()
        {
            SetGoogleCredentials();

            var accountLocation = Path.Combine(appFolder, googleAccountsFile);
            if(File.Exists(accountLocation))
            {
                string content = File.ReadAllText(accountLocation);
                var newObj = JObject.Parse(content);
                GoogleApi.AccountManager.FromJson(newObj);
            }
        }

        private string googleAppName;

        public string GoogleAppName
        {
            get { return googleAppName; }
            set
            {
                googleAppName = value.Trim();
                GoogleConnectionTested = ConfigState.Unknown;
            }
        }

        private string googleAppDomain;

        public string GoogleAppDomain
        {
            get { return googleAppDomain; }
            set
            {
                googleAppDomain = value.Trim();
                GoogleConnectionTested = ConfigState.Unknown;
            }
        }

        private string googleAdmin;

        public string GoogleAdmin
        {
            get { return googleAdmin; }
            set
            {
                googleAdmin =  value.Trim();
                GoogleConnectionTested = ConfigState.Unknown;
            }
        }

        private string googleApiKey = "";
        private string googleApiID = "";
        private string googleApiToken = "";

        public void SetGoogleSecret(string secret)
        {
            try
            {
                dynamic values = JsonConvert.DeserializeObject(secret);
                googleApiKey = values.private_key;
                googleApiID = values.client_id;
                googleApiToken = values.token_uri;
                GoogleConnectionTested = ConfigState.Unknown;
            }
            catch (Exception e)
            {
                MainWindow.Instance.Log.AddError(Origin.Google, e.Message);
            }
        }

        public bool IsGoogleSecretSet
        {
            get
            {
                if (googleApiKey == string.Empty) return false;
                if (googleApiToken == string.Empty) return false;
                if (googleApiID == string.Empty) return false;
                return true;
            }
        }

        private ConfigState googleConnectionTested;

        public ConfigState GoogleConnectionTested
        {
            get { return googleConnectionTested; }
            set
            {
                googleConnectionTested = value;
                ConfigChanged = true;
            }
        }

        public void SetGoogleCredentials()
        {
            googleConnectionTested = ConfigState.InProgress;
            bool result = GoogleApi.Connector.Init(
                googleAppName, 
                googleAdmin, 
                googleAppDomain, 
                googleApiKey, 
                googleApiID, 
                googleApiToken, 
                MainWindow.Instance.Log
            );
            if(result)
            {
                googleConnectionTested = ConfigState.OK;
            } else
            {
                googleConnectionTested = ConfigState.Failed;
            }
        }

        public async Task ReloadGoogleAccounts()
        {
            GoogleApi.AccountManager.ClearAll();
            await GoogleApi.AccountManager.ReloadAll();

            var json = GoogleApi.AccountManager.ToJson();
            var location = Path.Combine(appFolder, googleAccountsFile);
            File.WriteAllText(location, json.ToString());
        }
    }
}
