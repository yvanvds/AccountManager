using Microsoft.Graph;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Azure
{
    public class UserManager
    {
        private static UserManager instance = new UserManager();
        private UserManager() { }
        public static UserManager Instance { get { return instance; } }

        IList<Microsoft.Graph.User> users = new List<Microsoft.Graph.User>();
        public IList<Microsoft.Graph.User> Users => users;

        public async Task<bool> LoadFromAzure()
        {
            try
            {
                users = new List<Microsoft.Graph.User>();
                var options = new List<Option>
                {
                    new QueryOption("$select", "id, givenName, surName, displayName, mail, userPrincipalName, accountEnabled, employeeId, department, jobTitle")
                };
                var results = await Connector.Instance.Directory.Users.Request(options)
                    .GetAsync();

                
                while (results != null)
                {
                    users = users.Concat(results.CurrentPage).ToList();
                    Connector.Instance.RegisterMessage("" + users.Count + " gebruikers gevonden.");
                    if (results.NextPageRequest != null)
                    {
                        results = await results.NextPageRequest.GetAsync();
                    }
                    else results = null;
                    
                }
               
            }
            catch(ServiceException ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return false;
            }
            return true;
        }

        public JObject ToJson()
        {
            var result = new JObject();
            result["Users"] = JArray.FromObject(users);
            return result;
        }

        public void FromJson(JObject obj)
        {
            users.Clear();
            if (obj["Users"] is JArray)
            {
                users = (obj["Users"] as JArray).ToObject<List<Microsoft.Graph.User>>();
            }
        }
    }
}
