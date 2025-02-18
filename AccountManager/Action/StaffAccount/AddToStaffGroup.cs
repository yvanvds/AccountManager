using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    public class AddToStaffGroup : AccountAction
    {
        public AddToStaffGroup(): base(
            "Toevoegen aan SSM-Personeel in Office365",
            "Elk personeelslid hoort in het team personeel te zitten.",
            true, true)
        { }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            var user = account.Azure.Account;
            var secgroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName("SSM-Personeel", true);
            var group = AccountApi.Azure.GroupManager.Instance.FindGroupByName("SSM-Personeel", false);

            if (!group.HasMember(user)) await group.AddMember(user).ConfigureAwait(false);
            if (!secgroup.HasMember(user)) await secgroup.AddMember(user).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            var user = account.Azure.Account;
            var secgroup = AccountApi.Azure.GroupManager.Instance.FindGroupByName("SSM-Personeel", true);
            var group = AccountApi.Azure.GroupManager.Instance.FindGroupByName("SSM-Personeel", false);

            if (!secgroup.HasMember(user) || !group.HasMember(user))
            {
                account.Azure.FlagWarning();
                account.Actions.Add(new AddToStaffGroup());
            }
        }
    }
}
