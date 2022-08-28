using Microsoft.Graph;
using Microsoft.Identity.Client;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Interop;

namespace AccountApi.Azure
{
    public sealed class Connector : IAuthenticationProvider
    {
        

        private static string azureDomain;
        public string AzureDomain { get =>  Connector.azureDomain; }
        private static string prefix;
        public string Prefix { get => Connector.prefix; }

        private static string clientID;
        private static string tenantID;
        internal static System.Windows.Window parent;
        

        public static void Init(string clientID, string tenantID, System.Windows.Window parentWindow, string azureDomain, string schoolPrefix, ILog log = null)
        {
            Connector.azureDomain = azureDomain;
            prefix = schoolPrefix;
            Connector.log = log;
            Connector.parent = parentWindow;
            Connector.clientID = clientID;
            Connector.tenantID = tenantID;
        }

        private static Connector instance = null;
        private Connector() {
            parentWindow = parent;
            try
            {


                clientApp = PublicClientApplicationBuilder.Create(clientID)
                    .WithAuthority(AzureCloudInstance.AzurePublic, tenantID)
                    .WithDefaultRedirectUri()
                    .Build();
                TokenCacheHelper.EnableSerialization(clientApp.UserTokenCache);

                directory = new GraphServiceClient(this);
            }
            catch (Exception ex)
            {
                RegisterError($"Error Creating Azure App: {ex.Message}");
            }
        }
        public static Connector Instance
        {
            get
            {
                if (instance == null)
                {
                    instance = new Connector();
                    
                }
                return instance;
            }
        }

        private async Task<string> getAccessToken()
        {
            var accounts = await clientApp.GetAccountsAsync();
            var firstAccount = accounts.FirstOrDefault();
            AuthenticationResult authResult = null;

            try
            {
                authResult = await clientApp.AcquireTokenSilent(scopes, firstAccount).ExecuteAsync();
            }
            catch(MsalUiRequiredException)
            {
                // A MsalUiRequiredException happened on AcquireTokenSilent. 
                // This indicates you need to call AcquireTokenInteractive to acquire a token

                try
                {
                    authResult = await clientApp.AcquireTokenInteractive(scopes)
                        .WithAccount(accounts.FirstOrDefault())
                        .WithParentActivityOrWindow(new WindowInteropHelper(parentWindow).Handle)
                        .WithPrompt(Microsoft.Identity.Client.Prompt.SelectAccount)
                        .ExecuteAsync();
                }
                catch(MsalException msalex)
                {
                    RegisterError($"Error Acquiring Token:{msalex.Message}");
                }
            }
            catch(Exception ex)
            {
                RegisterError($"Error Acquiring Token Silently:{ex.Message}");
                return null;
            }

            if (authResult != null)
            {
                return authResult.AccessToken;
            }
            else return null;
        }


        public async Task AuthenticateRequestAsync(HttpRequestMessage request)
        {
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", await getAccessToken());
        }

        public void RegisterError(string message)
        {
            if (log != null)
            {
                log.AddError(Origin.Azure, message);
            }
        }

        public void RegisterMessage(string message)
        {
            if (log != null)
            {
                log.AddMessage(Origin.Azure, message);
            }
        }

        private static IPublicClientApplication clientApp;
        private string[] scopes = new string[] { "User.ReadWrite.All" };
        
        System.Windows.Window parentWindow = null;

        private static ILog log = null;

        private GraphServiceClient directory;
        public GraphServiceClient Directory => directory;
    }
}
