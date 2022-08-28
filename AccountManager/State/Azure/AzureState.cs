using AccountApi;
using AccountManager.Utils;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Azure
{
    public class AzureState : AbstractState
    {
        public ConfigValue<ConnectionState> Connection { get; private set; }
        public ConfigValue<string> ClientID { get; set; }
        public ConfigValue<string> TenantID { get; set; }

        public AzureAccounts Accounts { get; private set; } = new AzureAccounts();

        public AzureState()
        {
            ClientID = new ConfigValue<string>("clientID", "", UpdateObservers, UpdateConnectionState);
            TenantID = new ConfigValue<string>("tenantID", "", UpdateObservers, UpdateConnectionState);
            Connection = new ConfigValue<ConnectionState>("connectionTested", ConnectionState.Unknown, UpdateObservers);
        }

        public override void LoadConfig(JObject obj)
        {
            ClientID.Load(obj);
            TenantID.Load(obj);
            Connection.Load(obj);
        }

        public override JObject SaveConfig()
        {
            JObject result = new JObject();
            ClientID.Save(ref result);
            TenantID.Save(ref result);
            Connection.Save(ref result);
            return result;
        }

        public async Task Connect()
        {
            
            AccountApi.Azure.Connector.Instance.Create(ClientID.Value, TenantID.Value, MainWindow.Instance, App.Instance.AD.AzureDomain.Value, App.Instance.Settings.SchoolPrefix.Value, MainWindow.Instance.Log);
            //HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, "");
            //await AccountApi.Azure.Connector.Instance.AuthenticateRequestAsync(request).ConfigureAwait(false);
            //request.Dispose();
        }

        public override async Task LoadContent()
        {
            await Connect().ConfigureAwait(false);
            
            await Accounts.Load().ConfigureAwait(false);
        }

        public override void LoadLocalContent()
        {
            Accounts.LoadFromJson();
        }

        public override void SaveContent()
        {
            Accounts.SaveToJson();
        }

        public void UpdateConnectionState(ConnectionState state)
        {
            Connection.Value = state;
        }
    }
}
