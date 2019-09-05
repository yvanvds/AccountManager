using Google.Apis.Admin.Directory.directory_v1.Data;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Google
{
    public static class AccountManager
    {
        #region AccountList

        private static Dictionary<string, Account> allUsers = null;
        public static Dictionary<string, Account> All { get => allUsers; }

        public static void ClearAll()
        {
            if (allUsers != null)
            {
                allUsers.Clear();
                allUsers = null;
            }
        }

        public static async Task<bool> ReloadAll()
        {
            ClearAll();
            return await LoadAll();
        }

        public static async Task<bool> LoadAll()
        {
            if (allUsers != null && allUsers.Count > 0) return true;
            if (allUsers == null) allUsers = new Dictionary<string, Account>();

            var request = Connector.service.Users.List();
            request.Domain = Connector.Domain;

            bool result = await Task.Run(() =>
            {
                try
                {
                    int count = 0;
                    Users users = request.Execute();

                    if (users.UsersValue.Count > 0)
                    {
                        foreach (User user in users.UsersValue)
                        {
                            Account acc = ToAccount(user);
                            allUsers.Add(acc.UID, acc);
                            count++;
                        }
                    }

                    while (users.NextPageToken != null)
                    {

                        request.PageToken = users.NextPageToken;
                        users = request.Execute();

                        if (users.UsersValue.Count > 0)
                        {
                            foreach (User user in users.UsersValue)
                            {
                                Account acc = ToAccount(user);
                                allUsers.Add(acc.UID, acc);
                                count++;
                            }
                        }
                    }

                    Connector.Log.AddMessage(Origin.Google, "Added " + count.ToString() + " Accounts");
                    return true;
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Google, "Google Load Users list Error: " + e.Message);
                    return false;
                }
            });

            return result;
        }

        #endregion


        #region AccountManipulation
        public static async Task<Account> Load(string mailAddress)
        {
            var request = Connector.service.Users.Get(mailAddress);

            if (allUsers != null)
            {
                string key = mailAddress.Split('@')[0].ToLower();
                if (allUsers.ContainsKey(key))
                {
                    return allUsers[mailAddress.Split('@')[0].ToLower()];
                }
                return null;
            }

            // else load from google
            Account account = await Task.Run(() =>
            {
                try
                {
                    User user = request.Execute();
                    return ToAccount(user);
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Google, "Google Load User Error: " + e.Message);
                    return null;
                }
            });
            return account;
        }

        private static Account ToAccount(User user)
        {
            Account result = new Account
            {
                UID = user.PrimaryEmail.Split('@')[0]
            };
            if (user.Name != null)
            {
                result.GivenName = user.Name.GivenName;
                result.FamilyName = user.Name.FamilyName;
            }

            if (user.Aliases != null && user.Aliases.Count > 0)
            {
                result.MailAlias = user.Aliases[0];
            }
            else
            {
                result.MailAlias = "";
            }

            if (user.OrgUnitPath != null && user.OrgUnitPath.Equals("/personeel"))
            {
                result.IsStaff = true;
            }

            return result;
        }

        public static async Task<bool> Add(Account account, string password)
        {
            User user = new User
            {
                Name = new UserName
                {
                    GivenName = account.GivenName,
                    FamilyName = account.FamilyName,
                    FullName = account.FullName,
                },

                ChangePasswordAtNextLogin = false,
                PrimaryEmail = account.Mail,
                Password = password
            };

            if (account.IsStaff)
            {
                user.OrgUnitPath = "/personeel";
            }

            var request = Connector.service.Users.Insert(user);
            bool v = await Task.Run(() =>
            {
                try
                {
                    request.Execute();
                    return true;
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Google, "Google Add User Error: " + e.Message);
                    return false;
                }
            });
            if (v == false) return v;

            // alias must be added after creating the user
            Alias alias = new Alias
            {
                AliasValue = account.MailAlias
            };

            var aliasRequest = Connector.service.Users.Aliases.Insert(alias, account.Mail);
            v = await Task.Run(() =>
            {
                try
                {
                    aliasRequest.Execute();
                    return true;
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Google, "Google Add Alias Error: " + e.Message);
                    return false;
                }
            });

            if (v && allUsers != null && allUsers.Count > 0)
            {
                allUsers.Add(account.UID.ToLower(), account);
            }
            return v;
        }

        public static Account Find(string UID)
        {
            if (All.ContainsKey(UID)) return All[UID];
            return null;
        }

        public static async Task<bool> Delete(Account account)
        {
            var result = await Delete(account.Mail);
            if(result)
            {
                Connector.Log.AddMessage(Origin.Google, "Deleted " + account.UID);
            } else
            {
                Connector.Log.AddError(Origin.Google, "Unable to delete " + account.UID);
            }
            return result;
        }

        public static async Task<bool> Delete(string mailAddress)
        {
            var request = Connector.service.Users.Delete(mailAddress);
            bool result = await Task.Run(() =>
            {
                try
                {
                    request.Execute();
                    return true;
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Google, "Google Delete User Error: " + e.Message);
                    return false;
                }
            });

            if (result)
            {
                if (allUsers != null)
                {
                    string key = mailAddress.Split('@')[0].ToLower();
                    if (allUsers.ContainsKey(key))
                        allUsers.Remove(key);
                }
            }
            return result;
        }

        public static async Task<bool> ChangePassword(IAccount account, string password)
        {
            User user = new User
            {
                Password = password
            };

            var request = Connector.service.Users.Update(user, account.Mail);
            bool result = await Task.Run(() =>
            {
                try
                {
                    request.Execute();
                    return true;
                }
                catch (Exception e)
                {
                    Connector.Log.AddError(Origin.Google, "Google Change Password Error: " + e.Message);
                    return false;
                }

            });
            return result;
        }

        #endregion

        #region JSON
        public static JObject ToJson()
        {
            JObject result = new JObject();
            JArray arr = new JArray();
            if(allUsers != null)
            {
                foreach (var user in allUsers.Values)
                {
                    arr.Add(user.ToJson());
                }
                result["accounts"] = arr;
            }
            
            return result;
        }

        public static void FromJson(JObject obj)
        {
            allUsers = new Dictionary<string, Account>();
            if (obj.ContainsKey("accounts"))
            {
                var accounts = obj["accounts"].ToArray();
                foreach (var account in accounts)
                {
                    var acc = new Account(account as JObject);
                    allUsers.Add(acc.UID, acc);
                }
            }
        }
        #endregion
    }
}
