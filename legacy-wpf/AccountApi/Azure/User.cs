using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Azure
{
    public class User
    {
        public Microsoft.Graph.User Account;
        
        public User(Microsoft.Graph.User user)
        {
            Account = user;
        }

        public User(JObject obj)
        {
            Account = obj.ContainsKey("user") ? obj["user"].ToObject<Microsoft.Graph.User>() : null;
        }

        public JObject ToJson()
        {
            return new JObject
            {
                ["user"] = JObject.FromObject(Account),
            };
        }

        public string EmployeeId => Account.EmployeeId;
        public string UserPrincipalName => Account.UserPrincipalName;
        public string Id => Account.Id;
        public string DisplayName => Account.DisplayName;
        public string Department => Account.Department;
        public string CompanyName => Account.CompanyName;
        public string GivenName => Account.GivenName;
        public string Surname => Account.Surname;

        public void ChangePrincipalName(string newValue)
        {
            Account.UserPrincipalName = newValue;
        }

        public void ChangeCompanyName(string newValue)
        {
            Account.CompanyName = newValue;
        }

        public void ChangeGivenName(string newValue)
        {
            Account.GivenName = newValue;
        }
        public void ChangeDisplayName(string newValue)
        {
            Account.DisplayName = newValue;
        }
    }
}
