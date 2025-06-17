using Microsoft.Graph;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace AccountApi.Azure
{
    public class UserManager
    {
        private static UserManager instance = new UserManager();
        private UserManager() { }
        public static UserManager Instance { get { return instance; } }

        IList<User> users = new List<User>();
        public IList<User> Users => users;

        

        public async Task<bool> LoadFromAzure()
        {
            try
            {
                users = new List<User>();
                
                var options = new List<Option>
                {
                    new QueryOption("$select", "id, givenName, surname, displayName, mail, userPrincipalName, accountEnabled, employeeId, department, jobTitle, companyName")
                };
                var results = await Connector.Instance.Directory.Users.Request(options)
                    .GetAsync();

                
                while (results != null)
                {
                    foreach(var user in results.CurrentPage)
                    {
                        users.Add(new User(user));
                    }

                    Connector.Instance.RegisterMessage("" + users.Count + " gebruikers gevonden.");
                    if (results.NextPageRequest != null)
                    {
                        results = await results.NextPageRequest.GetAsync();
                    }
                    else results = null;
                    
                }
               
            }
            catch(Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return false;
            }
            return true;
        }

        public JObject ToJson()
        {
            var result = new JObject();
            var json = new JArray();
            foreach (var user in users)
            {
                json.Add(user.ToJson());
            }
            result["Users"] = json;
            return result;
        }

        public void FromJson(JObject obj)
        {
            users.Clear();
            var json = obj["Users"]?.ToArray();
            if (json != null) foreach(var item in json)
            {
                users.Add(new User(item as JObject));
            }
        }

        public User FindAccountByWisaID(String ID)
        {
            for(int i = 0; i < users.Count; i++)
            {
                if (users[i].EmployeeId == ID)
                {
                    return users[i];
                }
            }
            return null;
        }

        public User FindAccountByPrincipalName(String name)
        {
            for (int i = 0; i < users.Count; i++)
            {
                if (users[i].UserPrincipalName == name)
                {
                    return users[i];
                }
            }
            return null;
        }

        public async Task<Microsoft.Graph.User> CreateStudent(Wisa.Student student)
        {
            try
            {
                var principalName = await CreatePrincipalName(student.FirstName, student.Name, true);
                var mailNickName = principalName.Split('@')[0];

                var user = new Microsoft.Graph.User
                {
                    AccountEnabled = true,
                    GivenName = student.FirstName,
                    Surname = student.Name,
                    DisplayName = student.FullName,
                    UserPrincipalName = principalName,
                    EmployeeId = student.WisaID,
                    Department = student.ClassGroup,
                    JobTitle = "LeerlingSec",
                    Mail = principalName,
                    MailNickname = mailNickName,
                    UserType = "Member",
                    PasswordProfile = new PasswordProfile
                    {
                        ForceChangePasswordNextSignIn = false,
                        Password = Password.Create(), // Password does not matter, we create a new one when handing out accounts
                    }
                };

                return await CreateUser(user);
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return null;
            }

        }

        public async Task<Microsoft.Graph.User> CreateStaffMember(Wisa.Staff member)
        {
            try
            {
                var principalName = await CreatePrincipalName(member.FirstName, member.LastName, false);
                var mailNickName = principalName.Split('@')[0];

                var user = new Microsoft.Graph.User
                {
                    AccountEnabled = true,
                    GivenName = member.FirstName,
                    Surname = member.LastName,
                    DisplayName = member.FirstName + " " + member.LastName,
                    UserPrincipalName = principalName,
                    EmployeeId = member.WisaID,
                    Department = Connector.Instance.Prefix,
                    Mail = principalName,
                    MailNickname = mailNickName,
                    UserType = "Member",
                    PasswordProfile = new PasswordProfile
                    {
                        ForceChangePasswordNextSignIn = false,
                        Password = Password.Create(), // Password does not matter, we create a new one when handing out accounts
                    }
                };

                return await CreateUser(user);
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return null;
            }

        }

        private async Task<Microsoft.Graph.User> CreateUser(Microsoft.Graph.User user)
        {

            try
            {
                var newUser = await Connector.Instance.Directory.Users.Request().AddAsync(user);
                if (newUser != null)
                {
                    users.Add(new User(newUser));
                    return newUser;
                } else
                {
                    return null;
                }
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return null;
            }
        }

        public async Task<bool> DeleteUser(User user)
        {
            try
            {
                await Connector.Instance.Directory.Users[user.UserPrincipalName].Request().DeleteAsync();
                Users.Remove(user);
                return true;
            
            } catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return false;
            }
        }

        private async Task<string> CreatePrincipalName(string firstname, string lastname, bool isStudent)
        {
            firstname = firstname.Trim().ToLower();
            lastname = lastname.Trim().ToLower();

            string mail = firstname;
            mail += "."; mail += lastname;

            mail = mail.Replace('à', 'a');
            mail = mail.Replace('á', 'a');
            mail = mail.Replace('ä', 'a');
            mail = mail.Replace('è', 'e');
            mail = mail.Replace('é', 'e');
            mail = mail.Replace('ë', 'e');
            mail = mail.Replace('ï', 'i');
            mail = mail.Replace('ò', 'o');
            mail = mail.Replace('ó', 'o');
            mail = mail.Replace('ö', 'o');

            Regex rgx = new Regex("[^a-zA-Z_.+-]");
            mail = rgx.Replace(mail, "");

            int counter = 0;

            while (await DoesUserExist(mail + (counter > 0 ? counter.ToString() : "") + "@" + (isStudent ? "student." : "") + Connector.Instance.AzureDomain))
            {
                counter++;
            }

            return mail + (counter > 0 ? counter.ToString() : "") + "@" + (isStudent ? "student." : "") + Connector.Instance.AzureDomain;
        }

        private async Task<bool> DoesUserExist(String ID)
        {
            try
            {
                var user = await Connector.Instance.Directory.Users[ID].Request().GetAsync();
                return user != null;
            }
            catch (Exception ex)
            {
                //Connector.Instance.RegisterError(ex.Message);
                return false;
            }

        }

        public async Task<bool> SetPassword(User user, string newPassword)
        {
            try
            {
                await Connector.Instance.Directory.Users[user.UserPrincipalName].Authentication
                    .PasswordMethods["28c10230-6103-485e-b985-444c60001490"]
                    .ResetPassword(newPassword, true)
                    .Request()
                    .PostAsync();
                return true;
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return false;
            }
        } 

        public async Task GetPasswordMethodId(string id)
        {
            try
            {
                var result = await Connector.Instance.Directory.Users[id].Authentication.PasswordMethods.Request().GetAsync();
                foreach(var user in result)
                {
                    Connector.Instance.RegisterMessage(user.Id);
                }
                
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return ;
            }
        } 

        public async Task UpdatePrincipalName(string oldPrincipalName, User newValues)
        {
            try
            {
                var result = await Connector.Instance.Directory.Users[oldPrincipalName].Request().UpdateAsync(newValues.Account).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return;
            }
        }

        public async Task UpdateSchool( User user)
        {
            try
            {
                var result = await Connector.Instance.Directory.Users[user.UserPrincipalName].Request().UpdateAsync(user.Account).ConfigureAwait(false);
            } catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return;
            }
        }
    }
}
