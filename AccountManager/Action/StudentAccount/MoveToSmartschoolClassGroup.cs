using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class MoveToSmartschoolClassGroup : AccountAction
    {
        public MoveToSmartschoolClassGroup(string smartschoolClass, string wisaClass) : base(
            "Wijzig Klas in Smartschool",
            "De klas van dit account(" + smartschoolClass + ") komt niet overeen met de klas in Wisa(" + wisaClass + ")",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            var group = AccountApi.Smartschool.GroupManager.Root.Find(linkedAccount.Wisa.Account.ClassName);
            await Move(linkedAccount, group).ConfigureAwait(false);
        }

        /// <summary>
        /// Moves the account to the smartschool class. This is a static function because it can also be
        /// called from other actions, like adding the account
        /// </summary>
        /// <param name="linkedAccount"></param>
        /// <returns></returns>
        public static async Task Move(State.Linked.LinkedAccount linkedAccount, AccountApi.IGroup group)
        {
            if (group != null)
            {
                bool result = await AccountApi.Smartschool.GroupManager.MoveUserToClass(linkedAccount.Smartschool.Account, group, linkedAccount.Wisa.Account.ClassChange).ConfigureAwait(false);
                if (result)
                {
                    MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Smartschool, linkedAccount.Wisa.Account.FullName + " moved to " + linkedAccount.Wisa.Account.ClassName);
                }
                else
                {
                    MainWindow.Instance.Log.AddError(AccountApi.Origin.Smartschool, "Failed to move " + linkedAccount.Wisa.Account.FullName + " to " + linkedAccount.Wisa.Account.ClassName);
                }
            }
            else
            {
                MainWindow.Instance.Log.AddError(AccountApi.Origin.Smartschool, "Class " + linkedAccount.Wisa.Account.ClassName + " does not exist.");
            }
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Wisa.Account.ClassGroup.Contains("ANS") && !account.Wisa.Account.ClassGroup.Contains("BNS") && account.Wisa.Account.ClassName != account.Smartschool.Account.Group)
            {
                account.Actions.Add(new MoveToSmartschoolClassGroup(account.Smartschool.Account.Group, account.Wisa.Account.ClassName));
                account.Smartschool.FlagWarning();
                account.OK = false;
            }
        }
    }
}
